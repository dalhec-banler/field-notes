import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import 'area_downloader.dart';
import 'basemap_style.dart';
import 'mbtiles_store.dart';
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
      this.onController});

  final FieldNotesDb? db;
  final Property? property;
  final bool embedded;

  /// Hands the map controller up so chrome (capture-area mode) can read the
  /// visible region.
  final ValueChanged<MapLibreMapController>? onController;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  TileServer? _server;
  MbTilesStore? _mbtiles;
  String? _styleJson;
  String? _error;
  StreamSubscription<Position>? _fixSub;
  Position? _fix;
  bool _positionLayerReady = false;

  @override
  void initState() {
    super.initState();
    _start();
    _watchPosition();
  }

  Future<void> _start() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final basemapDir = Directory(p.join(docs.path, 'basemap'))
        ..createSync(recursive: true);
      // Captured areas (MBTiles) take precedence over a sideloaded PMTiles
      // archive; both serve through the same loopback server.
      final mbFile = File(p.join(basemapDir.path, AreaDownloader.mbtilesName));
      final pmFile = File(p.join(basemapDir.path, _basemapFile));
      if (mbFile.existsSync()) {
        _mbtiles = MbTilesStore.open(mbFile);
        final server =
            await TileServer.start(basemapDir, mbtiles: _mbtiles);
        final maxZoom =
            int.tryParse(_mbtiles!.metadata['maxzoom'] ?? '') ?? 15;
        setState(() {
          _server = server;
          _styleJson = basemapStyle(
              tilesUrl:
                  'http://127.0.0.1:${server.port}/mbtiles/{z}/{x}/{y}.pbf',
              maxZoom: maxZoom);
        });
      } else if (pmFile.existsSync()) {
        final server = await TileServer.start(basemapDir);
        setState(() {
          _server = server;
          _styleJson =
              basemapStyle(pmtilesUrl: server.pmtilesUrlFor(_basemapFile));
        });
      } else {
        setState(() => _error =
            'No offline basemap yet.\nUse capture-area on the map, or '
            'Settings → Offline maps.');
      }
    } catch (e) {
      setState(() => _error = 'Tile server failed to start: $e');
    }
  }

  void _watchPosition() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      _fixSub = Geolocator.getPositionStream(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.best),
      ).listen(_onFix);
    } catch (_) {}
  }

  Future<void> _onFix(Position pos) async {
    _fix = pos;
    final controller = _controller;
    if (controller == null || !_positionLayerReady) return;
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
    final centroid = widget.property?.centroidLat != null
        ? LatLng(widget.property!.centroidLat!, widget.property!.centroidLng!)
        // Lampasas River country until a boundary is imported.
        : const LatLng(31.06, -98.18);
    return Scaffold(
      body: MapLibreMap(
        styleString: _styleJson!,
        initialCameraPosition: CameraPosition(
          target: centroid,
          zoom: widget.property?.boundaryGeojson != null ? 14 : 11,
        ),
        myLocationEnabled: false,
        attributionButtonPosition: AttributionButtonPosition.bottomLeft,
        onMapCreated: _onMapCreated,
        onStyleLoadedCallback: () async {
          await _addOverlays();
          await _addPositionLayer();
        },
      ),
    );
  }

  MapLibreMapController? _controller;

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
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

    final obs = await (db.select(db.observations)
          ..where((o) => o.propertyId.equals(property.id))
          ..where((o) => o.deletedAt.isNull()))
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
              'properties': {'type': o.observationType},
            }
        ],
      });
      await controller.addCircleLayer(
        'observations',
        'observations-circles',
        const CircleLayerProperties(
          circleRadius: 7,
          circleColor: '#2f5233',
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 1.5,
        ),
      );
    }
  }
}
