import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Point, max;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_scope.dart';
import '../db/database.dart';
import '../geo/site_presence.dart';
import 'area_downloader.dart';
import 'basemap_style.dart';
import 'cluster_badge.dart';
import 'imagery_capture.dart';
import 'imagery_sources.dart';
import 'layers/map_layers.dart';
import 'map_markers.dart';
import 'record_clusters.dart';
import 'record_ink.dart';
import 'mbtiles_store.dart';
import 'pmtiles_reader.dart';
import 'tile_server.dart';
import '../services/diag.dart';

part 'map_screen/core.dart';
part 'map_screen/clusters.dart';
part 'map_screen/records.dart';
part 'map_screen/position.dart';
part 'map_screen/layers.dart';
part 'map_screen/gestures.dart';

const _basemapFile = 'basemap.pmtiles';

/// The style's layer ids for each kind of layer in the model — what the
/// layers sheet switches. 'satellite' is the imagery raster from
/// `basemap_style`; the rest are added by this screen.
const mapLayerIds = <MapLayerKind, List<String>>{
  MapLayerKind.imagery: ['satellite'],
  MapLayerKind.zones: ['zones-fill', 'zones-line'],
  MapLayerKind.boundary: ['boundary-line'],
  MapLayerKind.tracks: ['tracks-line'],
  MapLayerKind.features: ['features-fill', 'features-line', 'features-pt'],
  MapLayerKind.photoPoints: ['pp-wedge', 'pp-axis', 'pp-pt'],
  MapLayerKind.protocolSites: [],
  MapLayerKind.records: [
    'observations-circles',
    'observations-shapes',
    'observations-removal',
  ],
  MapLayerKind.clusters: ['obs-clusters-lyr'],
  MapLayerKind.position: ['me-accuracy', 'me-accuracy-edge', 'me-reticle'],
};

/// Map home screen (spec §7.1): offline basemap + property boundary, zone
/// overlays, and observation pins. Basemap archives live in
/// `<documents>/basemap/` and are served over loopback; nothing here touches
/// the network. What it draws is the one [MapLayerSet] (D-038 item 11);
/// this screen owns only how a layer becomes a MapLibre source.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    this.db,
    this.property,
    this.embedded = false,
    this.onController,
    this.onCoverage,
    this.onLongPress,
    this.visible = true,
    this.onRecordTap,
    this.onClusterTap,
    this.onFeatureTap,
    this.onPhotoPointTap,
    this.onLayersReady,
    this.onPresence,
    this.onRecordCount,
  });

  final FieldNotesDb? db;
  final Property? property;
  final bool embedded;

  /// Hands the map controller up so chrome (capture-area mode) can read the
  /// visible region.
  final ValueChanged<MapLibreMapController>? onController;

  /// Reports the offline basemap's bounds `[minLon, minLat, maxLon, maxLat]`
  /// so chrome can say "no map here yet" instead of showing blank paper.
  final ValueChanged<List<double>?>? onCoverage;

  /// Long-press on the map (spec §7.1: drop a record at an arbitrary point).
  final ValueChanged<LatLng>? onLongPress;

  /// False while another tab is showing: the live-position stream pauses.
  final bool visible;

  /// Tap on a record pin → its id.
  final ValueChanged<String>? onRecordTap;

  /// Tap on a cluster that can't split (or long-press on any dot): the
  /// records under it, for the "what's here" sheet.
  final ValueChanged<List<String>>? onClusterTap;

  /// Tap on a feature marker → its id.
  final ValueChanged<String>? onFeatureTap;

  /// Tap on a photo point station → its id.
  final ValueChanged<String>? onPhotoPointTap;

  /// Fired once the style and every overlay layer exist — the moment chrome
  /// can safely apply filters/visibility.
  final VoidCallback? onLayersReady;

  /// Whether the current fix is on this property, so the chrome can say so.
  final ValueChanged<SitePresence>? onPresence;

  /// How many located records are currently drawn.
  final ValueChanged<int>? onRecordCount;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

/// Split along its layers (D-038 item 7): state in `map_screen/core.dart`,
/// then clusters, the layer set and its GeoJSON, the live position, the
/// style's sources and layers, and gestures. The basemap start-up and the
/// lifecycle stay here. One object, seven files.
class _MapScreenState extends State<MapScreen>
    with
        WidgetsBindingObserver,
        _MapScreenCore,
        _MapScreenClusters,
        _MapScreenRecords,
        _MapScreenPosition,
        _MapScreenLayers,
        _MapScreenGestures {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scope.recordFilter.addListener(_refreshLayers);
    // Learn where this place is from its own records before deciding where
    // to open, for a property that has never had a boundary imported.
    _loadRecordCentre().whenComplete(() {
      if (mounted) setState(() => _centreResolved = true);
    });
    _start();
    _syncPositionWatch();
  }

  @override
  void didUpdateWidget(MapScreen old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) {
      _syncPositionWatch();
      // Back on the map after the ledger or a capture: whatever was
      // saved meanwhile is drawn now, not on the next camera idle.
      if (widget.visible) _refreshLayers();
    }
  }

  /// Battery (spec §7): the live dot only costs GPS while the map is on
  /// screen and the app is in front. Tracking keeps its own stream through
  /// the hub, so pausing here never touches a walk in progress.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
    _syncPositionWatch();
    if (_inForeground) _refreshLayers();
  }

  void _syncPositionWatch() {
    final want = widget.visible && _inForeground;
    if (want && _fixSub == null) {
      _watchPosition();
    } else if (!want && _fixSub != null) {
      _fixSub?.cancel();
      _fixSub = null;
    }
  }

  Future<void> _start() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final basemapDir = Directory(p.join(docs.path, 'basemap'))
        ..createSync(recursive: true);
      // Captured areas (MBTiles) draw first, but only when they actually
      // hold tiles — an empty store from a failed capture must not blank
      // the map. A sideloaded PMTiles archive fills in underneath through
      // the same merged endpoint.
      final mbFile = File(p.join(basemapDir.path, AreaDownloader.mbtilesName));
      final pmFile = File(p.join(basemapDir.path, _basemapFile));
      // Captured NAIP imagery, if any: the satellite layer serves it
      // offline through the loopback server.
      final imgFile = File(p.join(basemapDir.path, ImageryCapture.fileName));
      MbTilesStore? imagery;
      if (imgFile.existsSync()) {
        imagery = MbTilesStore.open(imgFile);
        if (imagery.tileCount == 0) {
          imagery.close();
          imagery = null;
        }
      }
      _imageryStore = imagery;
      final imgMaxZ = imagery == null
          ? 0
          : int.tryParse(imagery.metadata['maxzoom'] ?? '') ?? 0;
      MbTilesStore? mbtiles;
      if (mbFile.existsSync()) {
        mbtiles = MbTilesStore.open(mbFile);
        if (mbtiles.tileCount == 0) {
          mbtiles.close();
          mbtiles = null;
        }
      }
      if (mbtiles != null) {
        final TileServer server;
        try {
          server = await TileServer.start(
            basemapDir,
            imagery: imagery,
            mbtiles: mbtiles,
            pmtilesFallback: pmFile.existsSync() ? pmFile : null,
          );
        } catch (_) {
          mbtiles.close();
          rethrow;
        }
        if (!mounted) {
          // Rebuilt under a new key mid-await (property switch / capture):
          // release what we just opened instead of leaking it.
          await server.close();
          mbtiles.close();
          return;
        }
        _mbtiles = mbtiles;
        final mbMax = int.tryParse(mbtiles.metadata['maxzoom'] ?? '') ?? 15;
        final fbMax = server.fallbackMaxZoom ?? 0;
        final maxZoom = mbMax > fbMax ? mbMax : fbMax;
        // Coverage for the "no map here" hint: the regional file is the
        // wider of the two when present.
        List<double>? coverage;
        if (pmFile.existsSync()) {
          try {
            final src = FileRangeSource(pmFile);
            try {
              coverage = (await PmTilesReader.open(src)).header.bounds;
            } finally {
              src.close();
            }
          } catch (e, st) {
            Diag.report(e, st, where: 'MapScreen._start');
          }
        }
        if (coverage == null) {
          final boundsStr = mbtiles.metadata['bounds'];
          if (boundsStr != null) {
            final b = boundsStr
                .split(',')
                .map((s) => double.tryParse(s.trim()))
                .toList();
            if (b.length == 4 && !b.contains(null)) coverage = b.cast<double>();
          }
        }
        widget.onCoverage?.call(coverage);
        setState(() {
          _server = server;
          _styleJson = basemapStyle(
            tilesUrl: server.mbtilesUrlTemplate,
            maxZoom: maxZoom,
            satTemplate: server.satUrlTemplate,
            satMaxZoom: max(activeImagery.maxZoom, imgMaxZ),
          );
        });
      } else if (pmFile.existsSync()) {
        final server = await TileServer.start(basemapDir);
        if (!mounted) {
          await server.close();
          return;
        }
        // Header bounds tell the chrome where this archive actually has
        // tiles; a county extract on a phone in the city is blank paper.
        try {
          final src = FileRangeSource(pmFile);
          try {
            final reader = await PmTilesReader.open(src);
            widget.onCoverage?.call(reader.header.bounds);
          } finally {
            src.close();
          }
        } catch (e, st) {
          Diag.report(e, st, where: 'MapScreen._start');
        }
        if (!mounted) {
          await server.close();
          return;
        }
        setState(() {
          _server = server;
          _styleJson = basemapStyle(
            pmtilesUrl: server.pmtilesUrlFor(_basemapFile),
            satTemplate: server.satUrlTemplate,
            satMaxZoom: max(activeImagery.maxZoom, imgMaxZ),
          );
        });
      } else {
        // No archive on the phone: imagery-only, which needs signal but
        // beats a blank error screen. Capture an area to work offline.
        if (!mounted) return;
        setState(() {
          _styleJson = basemapStyle();
          _satelliteOnlyFallback = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Tile server failed to start: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scope.recordFilter.removeListener(_refreshLayers);
    _layerSub?.cancel();
    _fixSub?.cancel();
    _server?.close();
    _mbtiles?.close();
    _imageryStore?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Map')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    if (_styleJson == null || !_centreResolved) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final camera = _initialCamera ??= _decideCamera();
    return Scaffold(
      body: MapLibreMap(
        trackCameraPosition: true,
        styleString: _styleJson!,
        initialCameraPosition: camera,
        myLocationEnabled: false,
        attributionButtonPosition: AttributionButtonPosition.bottomLeft,
        onMapCreated: _onMapCreated,
        onMapLongClick: _onLongClick,
        onCameraIdle: _paintRecords,
        onStyleLoadedCallback: () async {
          await _addOverlays();
          await _addPositionLayer();
          await _frameRecordsIfNeeded();
          // Every layer now exists: chrome can apply its toggles.
          widget.onLayersReady?.call();
        },
      ),
    );
  }
}
