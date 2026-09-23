import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as mathlib;
import 'dart:math' show Point, max;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import '../geo/site_presence.dart';
import '../geo/view_wedge.dart';
import '../main.dart' show locationHub;
import 'area_downloader.dart';
import 'basemap_style.dart';
import 'cluster_badge.dart';
import 'imagery_capture.dart';
import 'imagery_sources.dart';
import 'map_markers.dart';
import 'record_clusters.dart';
import 'record_ink.dart';
import '../services/record_filter.dart';
import 'mbtiles_store.dart';
import 'pmtiles_reader.dart';
import 'tile_server.dart';

const _basemapFile = 'basemap.pmtiles';

/// Map home screen (spec §7.1): offline basemap + property boundary, zone
/// overlays, and observation pins. Basemap archives live in
/// `<documents>/basemap/` and are served over loopback; nothing here touches
/// the network.
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

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  TileServer? _server;
  MbTilesStore? _mbtiles;
  MbTilesStore? _imageryStore;
  String? _styleJson;
  String? _error;
  StreamSubscription<Position>? _fixSub;
  Position? _fix;
  bool _positionLayerReady = false;
  bool _inForeground = true;

  /// True when there is no offline basemap and we're drawing imagery only.
  bool _satelliteOnlyFallback = false;
  bool get satelliteOnlyFallback => _satelliteOnlyFallback;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    recordFilter.addListener(_refreshRecords);
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
      if (widget.visible) _refreshRecords();
    }
  }

  /// Battery (spec §7): the live dot only costs GPS while the map is on
  /// screen and the app is in front. Tracking keeps its own stream through
  /// the hub, so pausing here never touches a walk in progress.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
    _syncPositionWatch();
    if (_inForeground) _refreshRecords();
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
          } catch (_) {}
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
        } catch (_) {}
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

  bool _watching = false;

  void _watchPosition() async {
    if (_watching || _fixSub != null) return;
    _watching = true;
    try {
      if (!await locationHub.ensurePermission()) return;
      if (!mounted || !(widget.visible && _inForeground)) return;
      final last = locationHub.last;
      if (last != null) _onFix(last);
      _fixSub = locationHub.positions.listen(_onFix);
    } catch (_) {
    } finally {
      _watching = false;
    }
  }

  /// True once the camera has been centred on the user (at open, or on the
  /// first fix after opening without one). Never re-centres after that —
  /// the map is the user's to pan.
  /// Where the map opened, decided once. Recomputing this per build would
  /// be pointless (MapLibre reads it only at creation) and actively harmful,
  /// because deciding also decides whether the first fix should recentre.
  CameraPosition? _initialCamera;
  bool _openedOnFix = false;
  SitePresence? _presence;

  /// Standing on the place → open where you are. Somewhere else → open on
  /// the place; dragging the map 90 miles into town helps nobody. Knowing
  /// neither → open on the fix, and let the first fix recentre.
  CameraPosition _decideCamera() {
    final fresh = locationHub.fresh() ?? _fix;
    final property = widget.property;
    final presence = property == null
        ? SitePresence.unknown
        : presenceFor(property, fresh?.latitude, fresh?.longitude);
    final centre = property == null ? null : _centreFor(property);

    if (fresh != null && (presence.onSite || centre == null)) {
      _openedOnFix = true;
      return CameraPosition(
        target: LatLng(fresh.latitude, fresh.longitude),
        zoom: 16,
      );
    }
    if (centre != null) {
      // Off site: the place is the subject, and a later fix must not yank
      // the camera away from it.
      _openedOnFix = true;
      return CameraPosition(
        target: LatLng(centre[1], centre[0]),
        zoom: property?.boundaryGeojson != null ? 14 : 15,
      );
    }
    // Nothing known yet — no fix, no boundary, no records. Sit at a wide
    // view and let the first fix bring us somewhere real.
    _openedOnFix = false;
    return const CameraPosition(target: LatLng(39.5, -98.35), zoom: 3);
  }

  /// The property's own centre, or — for a place that has never had a
  /// boundary imported — the middle of the records already made on it.
  /// A place with fifty records in it knows perfectly well where it is.
  List<double>? _centreFor(Property property) =>
      propertyCentre(property) ?? _recordCentre;

  List<double>? _recordCentre;

  /// `[minLon, minLat, maxLon, maxLat]` of this property's records, when
  /// they're spread widely enough to be worth framing.
  List<double>? _recordBounds;

  /// Whether the record-centre lookup has finished. The camera is decided
  /// exactly once, so it must not be decided before we know where the
  /// property's records are — or a boundaryless place opens at a world view.
  bool _centreResolved = false;

  Future<void> _onFix(Position pos) async {
    _fix = pos;
    final property = widget.property;
    if (property != null) {
      final presence = presenceFor(property, pos.latitude, pos.longitude);
      if (presence.onSite != _presence?.onSite ||
          _presence == null ||
          ((presence.distanceM ?? 0) - (_presence!.distanceM ?? 0)).abs() >
              50) {
        _presence = presence;
        widget.onPresence?.call(presence);
      }
    }
    final controller = _controller;
    if (controller == null) return;
    if (!_openedOnFix && widget.visible) {
      _openedOnFix = true;
      try {
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 16),
        );
      } catch (_) {}
    }
    if (!_positionLayerReady) return;
    try {
      await controller.setGeoJsonSource('me', _positionGeoJson(pos));
    } catch (_) {}
  }

  Map<String, dynamic> _positionGeoJson(Position pos) {
    final acc = pos.accuracy;
    return {
      'type': 'FeatureCollection',
      'features': [
        if (acc.isFinite && acc > 1)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Polygon',
              'coordinates': [_accuracyRing(pos.latitude, pos.longitude, acc)],
            },
            'properties': {'acc': acc},
          },
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [pos.longitude, pos.latitude],
          },
          'properties': {'acc': acc},
        },
      ],
    };
  }

  /// The accuracy circle as ground coordinates, so it scales with the map
  /// instead of pretending to be a fixed number of pixels.
  static List<List<double>> _accuracyRing(
    double lat,
    double lng,
    double metres, {
    int steps = 36,
  }) {
    final dLat = metres / 111320.0;
    final dLng =
        metres / (111320.0 * mathlib.cos(lat * mathlib.pi / 180).abs());
    return [
      for (var i = 0; i <= steps; i++)
        [
          lng + dLng * mathlib.sin(2 * mathlib.pi * i / steps),
          lat + dLat * mathlib.cos(2 * mathlib.pi * i / steps),
        ],
    ];
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    recordFilter.removeListener(_refreshRecords);
    _recordSub?.cancel();
    _featureSub?.cancel();
    _photoPointSub?.cancel();
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

  MapLibreMapController? _controller;

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
    // Pin tap → the record. The plugin hands us the screen point; ask the
    // renderer what's under it so we get the feature's properties back.
    controller.onFeatureTapped.add((point, latLng, id, layerId, _) async {
      final hit = await _hitAt(point);
      if (hit == null) {
        final ppid = await _photoPointAt(point);
        if (ppid != null) {
          widget.onPhotoPointTap?.call(ppid);
          return;
        }
        final fid = await _featureAt(point);
        if (fid != null) widget.onFeatureTap?.call(fid);
        return;
      }
      if (!hit.isCluster) {
        widget.onRecordTap?.call(hit.ids.single);
        return;
      }
      // The Zillow move: land where the cluster splits; if it never does,
      // the sheet lists what's here.
      final zoom = controller.cameraPosition?.zoom ?? 15;
      final z = expansionZoom(hit.members, zoom);
      if (z != null) {
        final (lat, lng) = hit.centre;
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(lat, lng), z),
        );
      } else {
        widget.onClusterTap?.call(hit.ids);
      }
    });
    widget.onController?.call(controller);
  }

  Future<String?> _featureAt(Point<double> point) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final hits = await controller.queryRenderedFeatures(point, [
        'features-pt',
      ], null);
      for (final h in hits) {
        final fid = ((h as Map)['properties'] as Map?)?['fid'] as String?;
        if (fid != null) return fid;
      }
    } catch (_) {}
    return null;
  }

  /// What is under a screen point: a single record or a cluster, or null.
  Future<ClusterGroup?> _hitAt(Point<double> point) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final hits = await controller.queryRenderedFeatures(point, [
        'obs-clusters-lyr',
        'observations-circles',
        'observations-shapes',
      ], null);
      for (final h in hits) {
        final props = (h as Map)['properties'] as Map?;
        final id = props?['id'] as String?;
        if (id == null) continue;
        // Clusters resolve through the index the last paint built — no
        // member lists round-tripping through GeoJSON properties as CSV.
        final cluster = _clusterIndex[id];
        if (cluster != null) return cluster;
        final f = _recordFeatures
            .where((f) => (f['properties'] as Map)['id'] == id)
            .firstOrNull;
        if (f != null) return ClusterGroup([f]);
      }
    } catch (_) {}
    return null;
  }

  /// Long-press on a dot or cluster always opens the sheet; on bare map it
  /// keeps meaning "capture here".
  Future<void> _onLongClick(Point<double> point, LatLng latLng) async {
    final hit = await _hitAt(point);
    if (hit != null && widget.onClusterTap != null) {
      widget.onClusterTap!(hit.ids);
      return;
    }
    widget.onLongPress?.call(latLng);
  }

  /// Every located record as a GeoJSON feature — the clustering input.
  List<Map<String, dynamic>> _recordFeatures = const [];
  final Set<String> _badgeImages = {};

  /// Cluster feature id → its group, rebuilt by every paint. Taps resolve
  /// against this instead of parsing member ids out of rendered features.
  final Map<String, ClusterGroup> _clusterIndex = {};
  double? _lastPaintZoom;
  List<Map<String, dynamic>>? _lastPainted;
  bool _painting = false;
  bool _paintAgain = false;

  /// Regroup the pins for the current zoom and push them to the source.
  /// Runs on every camera idle and after every data refresh; a paint that
  /// arrives mid-paint queues one more, never a pile.
  Future<void> _paintRecords() async {
    final controller = _controller;
    if (controller == null || !_recordLayersReady) return;
    if (_painting) {
      _paintAgain = true;
      return;
    }
    _painting = true;
    // A platform call that never answers (the map covered by the camera,
    // the app asleep in a pocket) would otherwise hold _painting forever,
    // and every record saved after it would queue behind it until a
    // restart (Austin, 2026-09-07: "they don't pop up until I re-open").
    Future<T> bounded<T>(Future<T> call) =>
        call.timeout(const Duration(seconds: 8));
    try {
      final zoom = controller.cameraPosition?.zoom ?? 15;
      // Clustering depends only on zoom and the feature list: a pan-only
      // idle would re-push byte-identical sources over the channel.
      if (zoom == _lastPaintZoom && identical(_recordFeatures, _lastPainted)) {
        return;
      }
      final groups = clusterFeatures(_recordFeatures, zoom);
      final singles = <Map<String, dynamic>>[];
      final out = <Map<String, dynamic>>[];
      final index = <String, ClusterGroup>{};
      for (final g in groups) {
        if (!g.isCluster) {
          singles.add(g.members.single);
          continue;
        }
        final n = g.members.length;
        final icon = clusterIconKey(n);
        if (!_badgeImages.contains(icon)) {
          await bounded(controller.addImage(icon, await clusterBadge(n)));
          _badgeImages.add(icon);
        }
        final (lat, lng) = g.centre;
        // Content-derived id: stable across repaints while membership holds
        // (same-process only, which is all a tap lookup needs).
        final id = 'cluster:${g.ids.join(',').hashCode}';
        index[id] = g;
        out.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [lng, lat],
          },
          'properties': {'id': id, 'cluster': true, 'count': n, 'icon': icon},
        });
      }
      await bounded(
        controller.setGeoJsonSource('observations', {
          'type': 'FeatureCollection',
          'features': singles,
        }),
      );
      await bounded(
        controller.setGeoJsonSource('obs-clusters', {
          'type': 'FeatureCollection',
          'features': out,
        }),
      );
      _clusterIndex
        ..clear()
        ..addAll(index);
      _lastPaintZoom = zoom;
      _lastPainted = _recordFeatures;
    } catch (_) {
      // A repaint failure must never take the map down.
    } finally {
      _painting = false;
      if (_paintAgain) {
        _paintAgain = false;
        _paintRecords();
      }
    }
  }

  /// Current position: river-fill circle with a paper border and a soft
  /// ring (design §3.1 item 7) — drawn last so it sits above everything.
  Future<void> _addPositionLayer() async {
    final controller = _controller;
    if (controller == null) return;
    final seed = _fix;
    await controller.addGeoJsonSource(
      'me',
      seed != null
          ? _positionGeoJson(seed)
          : {'type': 'FeatureCollection', 'features': []},
    );
    // How well the phone knows where it is, drawn to scale on the ground
    // (design audit P3: accuracy was plumbed into the source and never
    // shown). A wide ring in the trees is the truth, not a defect.
    await controller.addFillLayer(
      'me',
      'me-accuracy',
      const FillLayerProperties(fillColor: '#1D6FE0', fillOpacity: 0.10),
      filter: [
        '==',
        ['geometry-type'],
        'Polygon',
      ],
    );
    await controller.addLineLayer(
      'me',
      'me-accuracy-edge',
      const LineLayerProperties(
        lineColor: '#1D6FE0',
        lineWidth: 1,
        lineOpacity: 0.35,
      ),
      filter: [
        '==',
        ['geometry-type'],
        'Polygon',
      ],
    );
    await controller.addImage('me-reticle', await positionReticle());
    await controller.addSymbolLayer(
      'me',
      'me-reticle',
      const SymbolLayerProperties(
        iconImage: 'me-reticle',
        iconSize: 1 / 3,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
    );
    _positionLayerReady = true;
  }

  /// Property boundary, zone fills, and observation pins from the local DB.
  Future<void> _addOverlays() async {
    final controller = _controller;
    final db = widget.db;
    final property = widget.property;
    if (controller == null || db == null || property == null) return;
    // A style (re)load drops every source, layer and image; forget what
    // was painted so the next paint pushes everything again.
    _recordLayersReady = false;
    _featureLayerReady = false;
    _photoPointLayerReady = false;
    _lastPainted = null;
    _lastPaintZoom = null;
    _badgeImages.clear();
    try {
      await _addPlaceOverlays(controller, db, property);
    } catch (_) {
      // Zones, boundary, photo points or features failing to draw must
      // not cost the record pins — those are what the map is for.
    }
    await _addRecordLayers(controller);
  }

  Future<void> _addPlaceOverlays(
    MapLibreMapController controller,
    FieldNotesDb db,
    Property property,
  ) async {
    final zones =
        await (db.select(db.zones)
              ..where((z) => z.propertyId.equals(property.id))
              ..where((z) => z.deletedAt.isNull()))
            .get();
    if (zones.isNotEmpty) {
      await controller.addGeoJsonSource('zones', {
        'type': 'FeatureCollection',
        'features': [
          for (final z in zones)
            {
              'type': 'Feature',
              'geometry': jsonDecode(z.geojson),
              'properties': {'name': z.name},
            },
        ],
      });
      await controller.addFillLayer(
        'zones',
        'zones-fill',
        const FillLayerProperties(fillColor: '#7d9b76', fillOpacity: 0.25),
      );
      await controller.addLineLayer(
        'zones',
        'zones-line',
        const LineLayerProperties(lineColor: '#5c7a55', lineWidth: 1.5),
      );
    }

    final boundary = property.boundaryGeojson;
    if (boundary != null) {
      await controller.addGeoJsonSource('boundary', {
        'type': 'Feature',
        'geometry': jsonDecode(boundary),
        'properties': <String, Object>{},
      });
      await controller.addLineLayer(
        'boundary',
        'boundary-line',
        // No lineDasharray: the plugin's Java property converter hits a JNI
        // toArray-on-null crash on dash arrays (observed on Android 36).
        const LineLayerProperties(lineColor: '#8a3324', lineWidth: 2.5),
      );
    }

    // Tracks (spec §4.13) as thin ink lines under the pins.
    final tracks =
        await (db.select(db.tracks)
              ..where((t) => t.propertyId.equals(property.id))
              ..where((t) => t.deletedAt.isNull())
              ..where((t) => t.geojson.isNotNull()))
            .get();
    if (tracks.isNotEmpty) {
      await controller.addGeoJsonSource('tracks', {
        'type': 'FeatureCollection',
        'features': [
          for (final t in tracks)
            {
              'type': 'Feature',
              'geometry': jsonDecode(t.geojson!),
              'properties': {'id': t.id},
            },
        ],
      });
      await controller.addLineLayer(
        'tracks',
        'tracks-line',
        const LineLayerProperties(
          lineColor: '#2C2620',
          lineWidth: 2,
          lineOpacity: 0.55,
        ),
      );
    }

    // Features (springs, guzzlers, headcuts…): silhouettes by class, so
    // they never read as records. Points are icons; lines and polygons
    // draw in the class colour.
    for (final cls in ['natural', 'infrastructure', 'problem']) {
      await controller.addImage('feature-$cls', await featureMarker(cls));
    }
    // Record shape language (2026-09-03): built things are squares, trouble
    // is a triangle — same silhouettes as the Features layer, but in the
    // record layer's paper stroke at record-dot weight.
    for (final e in const {
      'infrastructure': 'obs-square-ink',
      'maintenance': 'obs-square-ochre',
      'problem': 'obs-triangle',
    }.entries) {
      await controller.addImage(e.value, await recordShapeMarker(e.key));
    }
    await controller.addGeoJsonSource('features', _emptyCollection);
    await controller.addFillLayer(
      'features',
      'features-fill',
      const FillLayerProperties(fillColor: ['get', 'color'], fillOpacity: 0.22),
      filter: [
        '==',
        ['geometry-type'],
        'Polygon',
      ],
    );
    await controller.addLineLayer(
      'features',
      'features-line',
      const LineLayerProperties(lineColor: ['get', 'color'], lineWidth: 2.5),
      filter: [
        'in',
        ['geometry-type'],
        [
          'literal',
          ['LineString', 'Polygon'],
        ],
      ],
    );
    await controller.addSymbolLayer(
      'features',
      'features-pt',
      const SymbolLayerProperties(
        iconImage: ['get', 'icon'],
        iconSize: 1 / 3,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      filter: [
        '==',
        ['geometry-type'],
        'Point',
      ],
      enableInteraction: true,
    );
    // Photo points: the station, the ground it frames, and its axis —
    // a monitoring station is a spot AND a direction AND a field of view
    // (Austin, 2026-09-04).
    await controller.addImage('photo-point', await photoPointMarker());
    await controller.addGeoJsonSource('photopoints', _emptyCollection);
    await controller.addFillLayer(
      'photopoints',
      'pp-wedge',
      const FillLayerProperties(fillColor: '#D9A521', fillOpacity: 0.20),
      filter: [
        '==',
        ['geometry-type'],
        'Polygon',
      ],
    );
    await controller.addLineLayer(
      'photopoints',
      'pp-axis',
      const LineLayerProperties(
        lineColor: '#D9A521',
        lineWidth: 2,
        lineOpacity: 0.9,
      ),
      filter: [
        '==',
        ['geometry-type'],
        'LineString',
      ],
    );
    await controller.addSymbolLayer(
      'photopoints',
      'pp-pt',
      const SymbolLayerProperties(
        iconImage: 'photo-point',
        iconSize: 1 / 3,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      filter: [
        '==',
        ['geometry-type'],
        'Point',
      ],
      enableInteraction: true,
    );
    _photoPointLayerReady = true;
    await _refreshPhotoPoints();
    _photoPointSub?.cancel();
    _photoPointSub = db
        .changes({db.photoPoints})
        .listen((_) => _refreshPhotoPoints());

    _featureLayerReady = true;
    await _refreshFeatures();
    _featureSub?.cancel();
    _featureSub = db.changes({db.features}).listen((_) => _refreshFeatures());
  }

  /// Record pins. The source is created empty and then kept in step with
  /// the database by [_watchRecords] — a record saved five minutes from now
  /// has to appear without restarting the app.
  Future<void> _addRecordLayers(MapLibreMapController controller) async {
    for (final s in const ['flagged', 'removed']) {
      await controller.addImage('obs-removal-$s', await removalMarker(s));
    }
    await controller.addGeoJsonSource('observations', _emptyCollection);
    await controller.addCircleLayer(
      'observations',
      'observations-circles',
      CircleLayerProperties(
        // Plants keep the fine dot; everything else (infrastructure, water,
        // problems…) draws larger — the non-plant inks are dark and a 7.5px
        // dot in near-black disappears against imagery (Austin, 2026-09-02).
        circleRadius: [
          'match',
          ['get', 'kind'],
          [
            'tree',
            'shrub',
            'graminoid',
            'forb',
            'vine',
            'succulent',
            'fern',
            'moss',
            'plant',
          ],
          7.5,
          9.5,
        ],
        // A named plant is coloured by what kind of plant it is — trees,
        // shrubs, grasses and forbs read apart at a glance. Everything else
        // falls back to the kind of record it is.
        // A named plant is coloured by what kind of plant it is — trees,
        // shrubs, grasses and forbs read apart at a glance. Everything else
        // falls back to the kind of record it is.
        circleColor: kindColorMatch(),
        circleStrokeColor: '#ECE3CE',
        circleStrokeWidth: 1.5,
      ),
      // The shaped kinds draw in the symbol layer below instead.
      filter: [
        '!',
        [
          'in',
          ['get', 'kind'],
          [
            'literal',
            ['infrastructure', 'maintenance', 'problem'],
          ],
        ],
      ],
      enableInteraction: true,
    );
    // Shaped records: squares for built things, a triangle for problems.
    await controller.addSymbolLayer(
      'observations',
      'observations-shapes',
      const SymbolLayerProperties(
        iconImage: [
          'match',
          ['get', 'kind'],
          'infrastructure',
          'obs-square-ink',
          'maintenance',
          'obs-square-ochre',
          'obs-triangle',
        ],
        iconSize: 1 / 3,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      filter: [
        'in',
        ['get', 'kind'],
        [
          'literal',
          ['infrastructure', 'maintenance', 'problem'],
        ],
      ],
      enableInteraction: true,
    );
    // Removal (D-027) draws OVER the record's own mark: the ring and cut
    // say "this comes out", the dot beneath still says what it is.
    await controller.addSymbolLayer(
      'observations',
      'observations-removal',
      const SymbolLayerProperties(
        iconImage: [
          'match',
          ['get', 'removal'],
          'flagged',
          'obs-removal-flagged',
          'obs-removal-removed',
        ],
        iconSize: 1 / 3,
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      filter: [
        '!=',
        ['get', 'removal'],
        '',
      ],
      enableInteraction: true,
    );
    // Clusters: one badge with the count (image, so no glyphs needed).
    await controller.addGeoJsonSource('obs-clusters', _emptyCollection);
    await controller.addSymbolLayer(
      'obs-clusters',
      'obs-clusters-lyr',
      const SymbolLayerProperties(
        iconImage: ['get', 'icon'],
        iconSize: 1 / 3, // badges are drawn at 3× for crisp text
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ),
      enableInteraction: true,
    );
    _recordLayersReady = true;
    await _refreshRecords();
    _watchRecords();
  }

  bool _featureLayerReady = false;
  StreamSubscription<void>? _featureSub;
  bool _photoPointLayerReady = false;
  StreamSubscription<void>? _photoPointSub;

  /// Every photo point on this property: the station, its view wedge, and
  /// its axis. A point with no bearing yet (never captured) draws as a
  /// station only — it doesn't claim to look anywhere.
  Future<void> _refreshPhotoPoints() async {
    final db = widget.db;
    final property = widget.property;
    final controller = _controller;
    if (db == null || property == null || controller == null) return;
    if (!_photoPointLayerReady) return;
    try {
      final points =
          await (db.select(db.photoPoints)
                ..where((p) => p.propertyId.equals(property.id))
                ..where((p) => p.deletedAt.isNull()))
              .get();
      final out = <Map<String, dynamic>>[];
      for (final p in points) {
        out.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [p.lng, p.lat],
          },
          'properties': {'ppid': p.id, 'name': p.name},
        });
        if (p.bearingDeg == 0 && p.referenceMediaId == null) continue;
        final extent = p.viewExtentM ?? 60;
        out.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              viewWedge(
                lat: p.lat,
                lng: p.lng,
                bearingDeg: p.bearingDeg,
                focalLengthMm: p.focalLengthMm,
                extentM: extent,
              ),
            ],
          },
          'properties': {'ppid': p.id},
        });
        out.add({
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': viewAxis(
              lat: p.lat,
              lng: p.lng,
              bearingDeg: p.bearingDeg,
              extentM: extent,
            ),
          },
          'properties': {'ppid': p.id},
        });
      }
      await controller.setGeoJsonSource('photopoints', {
        'type': 'FeatureCollection',
        'features': out,
      });
    } catch (_) {}
  }

  Future<String?> _photoPointAt(Point<double> point) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final hits = await controller.queryRenderedFeatures(point, [
        'pp-pt',
      ], null);
      for (final h in hits) {
        final id = ((h as Map)['properties'] as Map?)?['ppid'] as String?;
        if (id != null) return id;
      }
    } catch (_) {}
    return null;
  }

  /// Every live feature on this property, coloured and iconed by class.
  Future<void> _refreshFeatures() async {
    final db = widget.db;
    final property = widget.property;
    final controller = _controller;
    if (db == null || property == null || controller == null) return;
    if (!_featureLayerReady) return;
    try {
      final rows = await db
          .customSelect(
            'SELECT f.id AS id, f.name AS name, f.geojson AS geojson, '
            't.feature_class AS cls, t.label AS label '
            'FROM features f JOIN feature_types t ON t.id = f.feature_type_id '
            'WHERE f.property_id = ? AND f.deleted_at IS NULL',
            variables: [Variable.withString(property.id)],
            readsFrom: {db.features, db.featureTypes},
          )
          .get();
      final out = <Map<String, dynamic>>[];
      for (final r in rows) {
        final cls = r.data['cls'] as String? ?? 'natural';
        Map<String, dynamic> geometry;
        try {
          geometry =
              jsonDecode(r.data['geojson'] as String) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        out.add({
          'type': 'Feature',
          'geometry': geometry,
          'properties': {
            'fid': r.data['id'],
            'name': r.data['name'] ?? r.data['label'],
            'cls': cls,
            'icon': 'feature-$cls',
            'color': switch (cls) {
              'problem' => '#8B2E22',
              'infrastructure' => '#1B1813',
              _ => '#2F5D8A',
            },
          },
        });
      }
      await controller.setGeoJsonSource('features', {
        'type': 'FeatureCollection',
        'features': out,
      });
    } catch (_) {}
  }

  static const _emptyCollection = {
    'type': 'FeatureCollection',
    'features': <Map<String, dynamic>>[],
  };

  bool _recordLayersReady = false;
  StreamSubscription<void>? _recordSub;

  /// Keep the pins in step with the ledger: any insert, edit or delete of an
  /// observation (or of the species library behind it) redraws the source.
  void _watchRecords() {
    final db = widget.db;
    if (db == null) return;
    _recordSub?.cancel();
    _recordSub = db
        .changes({db.observations, db.taxa})
        .listen((_) => _refreshRecords());
  }

  /// Every located record on this property, with the species and growth form
  /// the pin is drawn from.
  /// A property with no boundary yet, and records spread across it, should
  /// open showing all of them. initialCameraPosition can't express bounds,
  /// so the framing happens once the map is up.
  Future<void> _frameRecordsIfNeeded() async {
    final bounds = _recordBounds;
    final controller = _controller;
    if (bounds == null || controller == null || _framedRecords) return;
    if (_openedOnFix && (_presence?.onSite ?? false)) return;
    if (widget.property != null && propertyCentre(widget.property!) != null) {
      return; // the property knows its own place; leave the camera there
    }
    _framedRecords = true;
    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(bounds[1], bounds[0]),
            northeast: LatLng(bounds[3], bounds[2]),
          ),
          left: 48,
          right: 48,
          top: 150,
          bottom: 160,
        ),
      );
    } catch (_) {}
  }

  bool _framedRecords = false;

  /// Mean of located records — a stand-in centre for a property with no
  /// boundary yet, so the map opens on the work instead of nowhere.
  Future<void> _loadRecordCentre() async {
    final db = widget.db;
    final property = widget.property;
    if (db == null || property == null) return;
    if (propertyCentre(property) != null) return;
    try {
      final row = await db
          .customSelect(
            'SELECT AVG(lat) AS lat, AVG(lng) AS lng, COUNT(*) AS n, '
            'MIN(lat) AS min_lat, MAX(lat) AS max_lat, '
            'MIN(lng) AS min_lng, MAX(lng) AS max_lng '
            'FROM observations WHERE property_id = ? AND deleted_at IS NULL '
            'AND (gps_accuracy_m IS NULL OR gps_accuracy_m != -1)',
            variables: [Variable.withString(property.id)],
            readsFrom: {db.observations},
          )
          .getSingleOrNull();
      final n = (row?.data['n'] as int?) ?? 0;
      final lat = row?.data['lat'] as double?;
      final lng = row?.data['lng'] as double?;
      if (n > 0 && lat != null && lng != null) {
        _recordCentre = [lng, lat];
        final minLat = row?.data['min_lat'] as double?;
        final maxLat = row?.data['max_lat'] as double?;
        final minLng = row?.data['min_lng'] as double?;
        final maxLng = row?.data['max_lng'] as double?;
        if (n > 1 &&
            minLat != null &&
            maxLat != null &&
            minLng != null &&
            maxLng != null &&
            (maxLat - minLat > 0.0002 || maxLng - minLng > 0.0002)) {
          _recordBounds = [minLng, minLat, maxLng, maxLat];
        }
      }
    } catch (_) {}
  }

  Future<void> _refreshRecords() async {
    final db = widget.db;
    final property = widget.property;
    final controller = _controller;
    if (db == null || property == null || controller == null) return;
    if (!_recordLayersReady) return;
    try {
      final rows = await db
          .customSelect(
            'SELECT o.id AS id, o.lat AS lat, o.lng AS lng, '
            'o.observation_type AS type, o.gps_accuracy_m AS acc, '
            'o.taxon_id AS taxon, o.zone_id AS zone, '
            'o.observed_at AS at, '
            'o.removal_status AS removal, '
            't.growth_form AS growth, '
            'COALESCE(t.common_name, t.scientific_name) AS species '
            'FROM observations o LEFT JOIN taxa t ON t.id = o.taxon_id '
            'WHERE o.property_id = ? AND o.deleted_at IS NULL '
            'AND (o.gps_accuracy_m IS NULL OR o.gps_accuracy_m != -1)',
            variables: [Variable.withString(property.id)],
            readsFrom: {db.observations, db.taxa},
          )
          .get();
      // The ledger is the filter: the map draws exactly what it lists.
      final flt = recordFilter;
      String? dFrom;
      String? dTo;
      final dr = flt.dates;
      if (dr != null) {
        dFrom = DateTime(
          dr.start.year,
          dr.start.month,
          dr.start.day,
        ).toUtc().toIso8601String();
        dTo = DateTime(
          dr.end.year,
          dr.end.month,
          dr.end.day + 1,
        ).toUtc().toIso8601String();
      }
      final features = <Map<String, dynamic>>[];
      for (final r in rows) {
        final growth = r.data['growth'] as String?;
        final type = r.data['type'] as String? ?? 'general';
        final species = r.data['species'] as String?;
        if (flt.type != null && type != flt.type) continue;
        if (flt.flagged && r.data['removal'] != 'flagged') continue;
        if (flt.taxonId != null && r.data['taxon'] != flt.taxonId) continue;
        if (flt.zoneId != null && r.data['zone'] != flt.zoneId) continue;
        if (dFrom != null) {
          final at = r.data['at'] as String? ?? '';
          if (at.compareTo(dFrom) < 0 || at.compareTo(dTo!) >= 0) continue;
        }
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [r.data['lng'], r.data['lat']],
          },
          'properties': {
            'id': r.data['id'],
            'type': type,
            // What the pin is coloured by: growth form when the record
            // names a plant, otherwise the record type.
            'kind': growth ?? type,
            'growth': growth ?? '',
            'named': species != null,
            'species': species ?? '',
            'removal': (r.data['removal'] as String?) ?? '',
          },
        });
      }
      _recordFeatures = features;
      await _paintRecords();
      widget.onRecordCount?.call(features.length);
    } catch (_) {
      // A redraw failure must never take the map down.
    }
  }
}
