import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import '../main.dart' show locationHub;
import 'area_downloader.dart';
import 'basemap_style.dart';
import 'mbtiles_store.dart';
import 'pmtiles_reader.dart';
import 'tile_server.dart';

const _basemapFile = 'basemap.pmtiles';

/// Map home screen (spec §7.1): offline basemap + property boundary, zone
/// overlays, and observation pins. Basemap archives live in
/// `<documents>/basemap/` and are served over loopback; nothing here touches
/// the network.
class MapScreen extends StatefulWidget {
  const MapScreen(
      {super.key,
      this.db,
      this.property,
      this.embedded = false,
      this.onController,
      this.onCoverage,
      this.onLongPress,
      this.visible = true,
      this.onRecordTap,
      this.onLayersReady});

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

  /// Fired once the style and every overlay layer exist — the moment chrome
  /// can safely apply filters/visibility.
  final VoidCallback? onLayersReady;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  TileServer? _server;
  MbTilesStore? _mbtiles;
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
    _start();
    _syncPositionWatch();
  }

  @override
  void didUpdateWidget(MapScreen old) {
    super.didUpdateWidget(old);
    if (old.visible != widget.visible) _syncPositionWatch();
  }

  /// Battery (spec §7): the live dot only costs GPS while the map is on
  /// screen and the app is in front. Tracking keeps its own stream through
  /// the hub, so pausing here never touches a walk in progress.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
    _syncPositionWatch();
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
          server = await TileServer.start(basemapDir,
              mbtiles: mbtiles,
              pmtilesFallback: pmFile.existsSync() ? pmFile : null);
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
              tilesUrl: server.mbtilesUrlTemplate, maxZoom: maxZoom);
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
          _styleJson =
              basemapStyle(pmtilesUrl: server.pmtilesUrlFor(_basemapFile));
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
  bool _openedOnFix = false;

  Future<void> _onFix(Position pos) async {
    _fix = pos;
    final controller = _controller;
    if (controller == null) return;
    if (!_openedOnFix && widget.visible) {
      _openedOnFix = true;
      try {
        await controller.animateCamera(
            CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 16));
      } catch (_) {}
    }
    if (!_positionLayerReady) return;
    try {
      await controller.setGeoJsonSource('me', _positionGeoJson(pos));
    } catch (_) {}
  }

  Map<String, dynamic> _positionGeoJson(Position pos) => {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [pos.longitude, pos.latitude],
            },
            'properties': {'acc': pos.accuracy},
          }
        ],
      };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fixSub?.cancel();
    _server?.close();
    _mbtiles?.close();
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
    if (_styleJson == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // Open where you're standing (a fresh fix), else on the property, else
    // Lampasas River country until a boundary is imported.
    final fresh = locationHub.fresh() ?? _fix;
    final LatLng start;
    final double zoom;
    if (fresh != null) {
      start = LatLng(fresh.latitude, fresh.longitude);
      zoom = 16;
      _openedOnFix = true;
    } else if (widget.property?.centroidLat != null) {
      start = LatLng(
          widget.property!.centroidLat!, widget.property!.centroidLng!);
      zoom = widget.property?.boundaryGeojson != null ? 14 : 11;
    } else {
      start = const LatLng(31.06, -98.18);
      zoom = 11;
    }
    return Scaffold(
      body: MapLibreMap(
        styleString: _styleJson!,
        initialCameraPosition: CameraPosition(target: start, zoom: zoom),
        myLocationEnabled: false,
        attributionButtonPosition: AttributionButtonPosition.bottomLeft,
        onMapCreated: _onMapCreated,
        onMapLongClick: (_, latLng) => widget.onLongPress?.call(latLng),
        onStyleLoadedCallback: () async {
          await _addOverlays();
          await _addPositionLayer();
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
      if (widget.onRecordTap == null) return;
      try {
        final hits = await controller
            .queryRenderedFeatures(point, ['observations-circles'], null);
        for (final h in hits) {
          final props = (h as Map)['properties'] as Map?;
          final obsId = props?['id'] as String?;
          if (obsId != null) {
            widget.onRecordTap!(obsId);
            return;
          }
        }
      } catch (_) {}
    });
    widget.onController?.call(controller);
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
            : {'type': 'FeatureCollection', 'features': []});
    await controller.addCircleLayer(
      'me',
      'me-ring',
      const CircleLayerProperties(
        circleRadius: 14,
        circleColor: '#3F5957',
        circleOpacity: 0.28,
      ),
    );
    await controller.addCircleLayer(
      'me',
      'me-dot',
      const CircleLayerProperties(
        circleRadius: 7.5,
        circleColor: '#3F5957',
        circleStrokeColor: '#ECE3CE',
        circleStrokeWidth: 2.5,
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

    final zones = await (db.select(db.zones)
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
            }
        ],
      });
      await controller.addFillLayer(
        'zones',
        'zones-fill',
        const FillLayerProperties(
          fillColor: '#7d9b76',
          fillOpacity: 0.25,
        ),
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
        const LineLayerProperties(
          lineColor: '#8a3324',
          lineWidth: 2.5,
        ),
      );
    }

    // Tracks (spec §4.13) as thin ink lines under the pins.
    final tracks = await (db.select(db.tracks)
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
            }
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

    // Record pins: coloured by type, only records with a real location
    // (gps_accuracy_m = -1 is a stand-in coordinate, not a place).
    final obs = await (db.select(db.observations)
          ..where((o) => o.propertyId.equals(property.id))
          ..where((o) => o.deletedAt.isNull())
          ..where((o) =>
              o.gpsAccuracyM.isNull() | o.gpsAccuracyM.equals(-1).not()))
        .get();
    if (obs.isNotEmpty) {
      await controller.addGeoJsonSource('observations', {
        'type': 'FeatureCollection',
        'features': [
          for (final o in obs)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [o.lng, o.lat],
              },
              'properties': {'id': o.id, 'type': o.observationType},
            }
        ],
      });
      await controller.addCircleLayer(
        'observations',
        'observations-circles',
        const CircleLayerProperties(
          circleRadius: 7.5,
          circleColor: [
            'match',
            ['get', 'type'],
            'plant', '#5F6B58',
            'wildlife', '#8E6A28',
            'problem', '#7A2E1E',
            'water', '#3F5957',
            'soil', '#6B4F2A',
            'phenology', '#5C7A78',
            'sign', '#8E6A28',
            'weather', '#5E6E8C',
            'maintenance', '#2C2620',
            '#2f5233',
          ],
          circleStrokeColor: '#ECE3CE',
          circleStrokeWidth: 1.5,
        ),
        enableInteraction: true,
      );
    }
  }
}
