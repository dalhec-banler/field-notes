import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import 'basemap_style.dart';
import 'tile_server.dart';

const _basemapFile = 'basemap.pmtiles';

/// Map home screen (spec §7.1): offline basemap + property boundary, zone
/// overlays, and observation pins. Basemap archives live in
/// `<documents>/basemap/` and are served over loopback; nothing here touches
/// the network.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.db, this.property});

  final FieldNotesDb? db;
  final Property? property;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  TileServer? _server;
  String? _styleJson;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final basemapDir = Directory(p.join(docs.path, 'basemap'));
      final archive = File(p.join(basemapDir.path, _basemapFile));
      if (!archive.existsSync()) {
        setState(() => _error =
            'No offline basemap installed.\nExpected ${archive.path}');
        return;
      }
      final server = await TileServer.start(basemapDir);
      setState(() {
        _server = server;
        _styleJson =
            basemapStyle(pmtilesUrl: server.pmtilesUrlFor(_basemapFile));
      });
    } catch (e) {
      setState(() => _error = 'Tile server failed to start: $e');
    }
  }

  @override
  void dispose() {
    _server?.close();
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
        onStyleLoadedCallback: () => _addOverlays(),
      ),
    );
  }

  MapLibreMapController? _controller;

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
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
