import 'dart:io';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'basemap_style.dart';
import 'tile_server.dart';

const _basemapFile = 'basemap.pmtiles';

/// Map home screen (spec §7.1) — currently the PMTiles offline prototype.
/// Basemap archives live in `<documents>/basemap/` and are served over
/// loopback; nothing here touches the network.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

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
    return Scaffold(
      body: MapLibreMap(
        styleString: _styleJson!,
        initialCameraPosition: const CameraPosition(
          // Lampasas River country until the property boundary is imported.
          target: LatLng(31.06, -98.18),
          zoom: 11,
        ),
        myLocationEnabled: false,
        attributionButtonPosition: AttributionButtonPosition.bottomLeft,
      ),
    );
  }
}
