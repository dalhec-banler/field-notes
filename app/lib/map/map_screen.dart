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
import '../geo/site_presence.dart';
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
      this.onLayersReady,
      this.onPresence,
      this.onRecordCount});

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
  SitePresence? _presence;

  Future<void> _onFix(Position pos) async {
    _fix = pos;
    final property = widget.property;
    if (property != null) {
      final presence =
          presenceFor(property, pos.latitude, pos.longitude);
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
    _recordSub?.cancel();
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
    // Standing on the place → open where you are. Somewhere else → open on
    // the place; dragging the map 90 miles into town helps nobody.
    final fresh = locationHub.fresh() ?? _fix;
    final property = widget.property;
    final presence = property == null
        ? SitePresence.unknown
        : presenceFor(property, fresh?.latitude, fresh?.longitude);
    final centre = property == null ? null : propertyCentre(property);
    final LatLng start;
    final double zoom;
    if (fresh != null && (presence.onSite || centre == null)) {
      start = LatLng(fresh.latitude, fresh.longitude);
      zoom = 16;
      _openedOnFix = true;
    } else if (centre != null) {
      start = LatLng(centre[1], centre[0]);
      zoom = property?.boundaryGeojson != null ? 14 : 13;
      // Off site: never yank the camera to the phone when a fix lands.
      _openedOnFix = true;
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

    // Record pins. The source is created empty and then kept in step with
    // the database by [_watchRecords] — a record saved five minutes from now
    // has to appear without restarting the app.
    await controller.addGeoJsonSource('observations', _emptyCollection);
    await controller.addCircleLayer(
      'observations',
      'observations-circles',
      const CircleLayerProperties(
        circleRadius: 7.5,
        // A named plant is coloured by what kind of plant it is — trees,
        // shrubs, grasses and forbs read apart at a glance. Everything else
        // falls back to the kind of record it is.
        circleColor: [
          'match',
          ['get', 'kind'],
          'tree', '#3F5957',
          'shrub', '#5F6B58',
          'graminoid', '#B58A3C',
          'forb', '#8E6A28',
          'vine', '#5C7A78',
          'succulent', '#8E9B85',
          'fern', '#6B8F71',
          'moss', '#6B8F71',
          'wildlife', '#7A5C2E',
          'problem', '#7A2E1E',
          'water', '#5E6E8C',
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
    // Named species get a ring, so a documented plant stands out from a
    // general note at a glance.
    await controller.addCircleLayer(
      'observations',
      'observations-named',
      const CircleLayerProperties(
        circleRadius: 12,
        circleColor: '#00000000',
        circleStrokeColor: '#1B1813',
        circleStrokeWidth: 1.2,
        circleOpacity: 0,
      ),
      filter: ['==', ['get', 'named'], true],
    );
    _recordLayersReady = true;
    await _refreshRecords();
    _watchRecords();
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
        .customSelect('SELECT 1',
            readsFrom: {db.observations, db.taxa})
        .watch()
        .listen((_) => _refreshRecords());
  }

  /// Every located record on this property, with the species and growth form
  /// the pin is drawn from.
  Future<void> _refreshRecords() async {
    final db = widget.db;
    final property = widget.property;
    final controller = _controller;
    if (db == null || property == null || controller == null) return;
    if (!_recordLayersReady) return;
    try {
      final rows = await db.customSelect(
        'SELECT o.id AS id, o.lat AS lat, o.lng AS lng, '
        'o.observation_type AS type, o.gps_accuracy_m AS acc, '
        't.growth_form AS growth, '
        'COALESCE(t.common_name, t.scientific_name) AS species '
        'FROM observations o LEFT JOIN taxa t ON t.id = o.taxon_id '
        'WHERE o.property_id = ? AND o.deleted_at IS NULL '
        'AND (o.gps_accuracy_m IS NULL OR o.gps_accuracy_m != -1)',
        variables: [Variable.withString(property.id)],
        readsFrom: {db.observations, db.taxa},
      ).get();
      final features = <Map<String, dynamic>>[];
      for (final r in rows) {
        final growth = r.data['growth'] as String?;
        final type = r.data['type'] as String? ?? 'general';
        final species = r.data['species'] as String?;
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
          },
        });
      }
      await controller.setGeoJsonSource(
          'observations', {'type': 'FeatureCollection', 'features': features});
      widget.onRecordCount?.call(features.length);
    } catch (_) {
      // A redraw failure must never take the map down.
    }
  }
}
