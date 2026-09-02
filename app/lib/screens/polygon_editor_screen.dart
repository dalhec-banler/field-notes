import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../db/database.dart';
import '../export/plate_subject_loader.dart' show acresOf;
import '../export/web_mercator.dart' show metresPerPixel;
import '../geo/simplify.dart' show distanceM;
import '../geo/site_presence.dart' show propertyCentre;
import '../geo/zone_assignment.dart';
import '../map/basemap_style.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Trace and adjust a polygon on the imagery (Austin, 2026-09-01): drag
/// corners, drag a midpoint ghost to grow a new corner, undo/redo, live
/// acreage. This kills the Google-Earth/KML round trip for zones — the
/// boundary and every zone are editable where the pixels are.
///
/// Tracing against imagery is the tool; there is deliberately no
/// walk-the-boundary-from-GPS mode ("too messy and gps isnt accurate
/// enough").
class PolygonEditorScreen extends StatefulWidget {
  const PolygonEditorScreen.boundary({
    super.key,
    required this.db,
    required this.property,
    this.initialTarget,
  }) : zone = null,
       isBoundary = true;

  const PolygonEditorScreen.zone({
    super.key,
    required this.db,
    required this.property,
    required Zone this.zone,
    this.initialTarget,
  }) : isBoundary = false;

  const PolygonEditorScreen.newZone({
    super.key,
    required this.db,
    required this.property,
    this.initialTarget,
  }) : zone = null,
       isBoundary = false;

  final FieldNotesDb db;
  final Property property;
  final Zone? zone;
  final bool isBoundary;

  /// Where to open when there is no shape yet (the map hands over its own
  /// centre so a new place never opens on the fallback coordinates).
  final LatLng? initialTarget;

  @override
  State<PolygonEditorScreen> createState() => _PolygonEditorScreenState();
}

class _PolygonEditorScreenState extends State<PolygonEditorScreen> {
  MapLibreMapController? _map;
  final List<LatLng> _ring = [];
  final List<List<LatLng>> _undo = [];
  final List<List<LatLng>> _redo = [];

  Fill? _fill;
  Line? _outline;
  final Map<String, int> _vertexIdx = {}; // circle id → ring index
  final Map<String, int> _midIdx = {}; // circle id → insert-before index
  final List<Circle> _circles = [];
  int? _selected;
  bool _dirty = false;

  /// Crosshair mode: the grabbed corner follows the map centre until SET.
  int? _placing;
  LatLng? _placingOriginal;
  bool _placingIsNew = false;

  String get _title =>
      widget.isBoundary ? 'Boundary' : widget.zone?.name ?? 'New zone';

  @override
  void initState() {
    super.initState();
    final geojson = widget.isBoundary
        ? widget.property.boundaryGeojson
        : widget.zone?.geojson;
    if (geojson != null) {
      try {
        final g = jsonDecode(geojson) as Map<String, dynamic>;
        final coords = g['type'] == 'Polygon'
            ? (g['coordinates'] as List).first as List
            : (((g['coordinates'] as List).first as List).first as List);
        for (final c in coords) {
          _ring.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
        }
        // Drop the GeoJSON closing duplicate; the editor works on the open ring.
        if (_ring.length > 1 &&
            _ring.first.latitude == _ring.last.latitude &&
            _ring.first.longitude == _ring.last.longitude) {
          _ring.removeLast();
        }
      } catch (_) {}
    }
  }

  CameraPosition get _camera {
    if (_ring.isNotEmpty) {
      var lat = 0.0, lng = 0.0;
      for (final p in _ring) {
        lat += p.latitude;
        lng += p.longitude;
      }
      return CameraPosition(
        target: LatLng(lat / _ring.length, lng / _ring.length),
        zoom: 15.5,
      );
    }
    final c = propertyCentre(widget.property);
    return CameraPosition(
      target:
          widget.initialTarget ??
          (c == null ? const LatLng(31.06, -98.05) : LatLng(c[1], c[0])),
      zoom: 15,
    );
  }

  String get _acres {
    if (_ring.length < 3) return '';
    final a = acresOf(_ringGeojson());
    return a == null ? '' : '${a.toStringAsFixed(1)} ac';
  }

  String _ringGeojson() {
    final closed = [
      for (final p in _ring) [p.longitude, p.latitude],
      [_ring.first.longitude, _ring.first.latitude],
    ];
    return jsonEncode({
      'type': 'Polygon',
      'coordinates': [closed],
    });
  }

  void _snapshot() {
    _undo.add(List.of(_ring));
    if (_undo.length > 60) _undo.removeAt(0);
    _redo.clear();
    _dirty = true;
  }

  Future<void> _redraw() async {
    final map = _map;
    if (map == null) return;
    // Authoritative wipe: stale annotation objects survived id-based
    // removal on Android, leaving the outline one edit behind.
    try {
      await map.clearCircles();
      await map.clearFills();
      await map.clearLines();
    } catch (_) {}
    _circles.clear();
    _vertexIdx.clear();
    _midIdx.clear();
    _fill = null;
    _outline = null;

    final ringClosed = _ring.length >= 3
        ? [..._ring, _ring.first]
        : List.of(_ring);
    if (_ring.length >= 3) {
      _fill = await map.addFill(
        FillOptions(
          geometry: [ringClosed],
          fillColor: '#4E6B4A',
          fillOpacity: 0.22,
        ),
      );
    }
    if (_ring.length >= 2) {
      _outline = await map.addLine(
        LineOptions(geometry: ringClosed, lineColor: '#8B2E22', lineWidth: 3),
      );
    }

    // Midpoint ghosts first so real corners draw over them.
    if (_ring.length >= 2) {
      for (var i = 0; i < _ring.length; i++) {
        final a = _ring[i];
        final b = _ring[(i + 1) % _ring.length];
        if (_ring.length == 2 && i == 1) break; // one segment, one ghost
        final mid = LatLng(
          (a.latitude + b.latitude) / 2,
          (a.longitude + b.longitude) / 2,
        );
        final ghost = await map.addCircle(
          CircleOptions(
            geometry: mid,
            circleRadius: 8,
            circleColor: '#F7F6F2',
            circleOpacity: 0.6,
            circleStrokeColor: '#8B2E22',
            circleStrokeWidth: 1.5,
          ),
        );
        _circles.add(ghost);
        _midIdx[ghost.id] = i + 1;
      }
    }
    for (var i = 0; i < _ring.length; i++) {
      final v = await map.addCircle(
        CircleOptions(
          geometry: _ring[i],
          circleRadius: 10,
          circleColor: i == _selected ? '#8B2E22' : '#F7F6F2',
          circleStrokeColor: '#8B2E22',
          circleStrokeWidth: 3,
        ),
      );
      _circles.add(v);
      _vertexIdx[v.id] = i;
    }
    if (mounted) setState(() {});
  }

  Future<void> _liveGeometry() async {
    final map = _map;
    if (map == null) return;
    final ringClosed = [..._ring, if (_ring.isNotEmpty) _ring.first];
    if (_fill != null && _ring.length >= 3) {
      await map.updateFill(_fill!, FillOptions(geometry: [ringClosed]));
    }
    if (_outline != null && _ring.length >= 2) {
      await map.updateLine(_outline!, LineOptions(geometry: ringClosed));
    }
  }

  void _onCameraMove() {
    final i = _placing;
    final map = _map;
    if (i == null || map == null) return;
    final pos = map.cameraPosition;
    if (pos == null || i >= _ring.length) return;
    _ring[i] = pos.target;
    _liveGeometry();
    if (mounted) setState(() {}); // acreage follows the pan
  }

  Future<void> _beginPlacing(int index, {required bool isNew}) async {
    final map = _map;
    if (map == null) return;
    _snapshot();
    setState(() {
      _placingIsNew = isNew;
      _placingOriginal = _ring[index];
      _selected = null;
    });
    await _redraw();
    // Fly to the corner FIRST; only then arm the follow — arming during
    // the flight dragged the corner to wherever the camera started.
    try {
      await map.animateCamera(CameraUpdate.newLatLng(_ring[index]));
    } catch (_) {}
    if (!mounted) return;
    setState(() => _placing = index);
  }

  Future<void> _setPlaced() async {
    setState(() {
      _placing = null;
      _placingOriginal = null;
      _placingIsNew = false;
    });
    await _redraw();
  }

  Future<void> _cancelPlacing() async {
    final i = _placing;
    if (i != null) {
      if (_placingIsNew) {
        _ring.removeAt(i);
      } else if (_placingOriginal != null) {
        _ring[i] = _placingOriginal!;
      }
      // The snapshot from _beginPlacing is now moot.
      if (_undo.isNotEmpty) _undo.removeLast();
    }
    setState(() {
      _placing = null;
      _placingOriginal = null;
      _placingIsNew = false;
    });
    await _redraw();
  }

  Future<void> _deletePlacing() async {
    final i = _placing;
    if (i == null || _ring.length <= 3) return;
    _ring.removeAt(i);
    setState(() {
      _placing = null;
      _placingOriginal = null;
      _placingIsNew = false;
    });
    await _redraw();
  }

  Future<void> _onMapTap(dynamic point, LatLng latLng) async {
    if (_placing != null) return;
    // Building a new shape: every tap is a corner until there are three.
    if (_ring.length < 3) {
      _snapshot();
      _ring.add(latLng);
      _redraw();
      return;
    }
    // Manual hit-test in GEOGRAPHIC space: the click's logical pixels and
    // toScreenLocation's device pixels don't agree on Android, so distance
    // is measured in metres against the metre size of a thumb at this zoom.
    final map = _map;
    if (map == null) return;
    final zoom = (map.cameraPosition?.zoom ?? 16).round();
    final hitM = metresPerPixel(latLng.latitude, zoom) * 34;
    double dTo(LatLng p) => distanceM(
      [latLng.longitude, latLng.latitude],
      [p.longitude, p.latitude],
    );
    double best = double.infinity;
    int? bestVertex;
    for (var i = 0; i < _ring.length; i++) {
      final d = dTo(_ring[i]);
      if (d < best) {
        best = d;
        bestVertex = i;
      }
    }
    if (bestVertex != null && best <= hitM) {
      _beginPlacing(bestVertex, isNew: false);
      return;
    }
    best = double.infinity;
    int? bestMid;
    for (var i = 0; i < _ring.length; i++) {
      final a = _ring[i];
      final b = _ring[(i + 1) % _ring.length];
      final mid = LatLng(
        (a.latitude + b.latitude) / 2,
        (a.longitude + b.longitude) / 2,
      );
      final d = dTo(mid);
      if (d < best) {
        best = d;
        bestMid = i + 1;
      }
    }
    if (bestMid != null && best <= hitM) {
      final a = _ring[bestMid - 1];
      final b = _ring[bestMid % _ring.length];
      _ring.insert(
        bestMid,
        LatLng((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2),
      );
      _beginPlacing(bestMid, isNew: true);
    }
  }

  void _onCircleTap(Circle circle) {
    if (_placing != null) return;
    final i = _vertexIdx[circle.id];
    if (i != null) {
      _beginPlacing(i, isNew: false);
      return;
    }
    final at = _midIdx[circle.id];
    if (at != null) {
      final a = _ring[at - 1];
      final b = _ring[at % _ring.length];
      _ring.insert(
        at,
        LatLng((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2),
      );
      _beginPlacing(at, isNew: true);
    }
  }

  void _undoOnce() {
    if (_undo.isEmpty) return;
    _redo.add(List.of(_ring));
    _ring
      ..clear()
      ..addAll(_undo.removeLast());
    _selected = null;
    _redraw();
  }

  void _redoOnce() {
    if (_redo.isEmpty) return;
    _undo.add(List.of(_ring));
    _ring
      ..clear()
      ..addAll(_redo.removeLast());
    _selected = null;
    _redraw();
  }

  Future<void> _save() async {
    if (_ring.length < 3) return;
    final db = widget.db;
    final now = nowUtcIso();
    final geojson = _ringGeojson();
    final acres = acresOf(geojson);
    if (widget.isBoundary) {
      var lat = 0.0, lng = 0.0;
      for (final p in _ring) {
        lat += p.latitude;
        lng += p.longitude;
      }
      await (db.update(
        db.properties,
      )..where((p) => p.id.equals(widget.property.id))).write(
        PropertiesCompanion(
          boundaryGeojson: Value(geojson),
          centroidLat: Value(lat / _ring.length),
          centroidLng: Value(lng / _ring.length),
          acreage: Value(acres),
          updatedAt: Value(now),
        ),
      );
    } else if (widget.zone != null) {
      await (db.update(
        db.zones,
      )..where((z) => z.id.equals(widget.zone!.id))).write(
        ZonesCompanion(
          geojson: Value(geojson),
          areaAcres: Value(acres),
          updatedAt: Value(now),
        ),
      );
    } else {
      final name = await _askName();
      if (name == null || name.trim().isEmpty) return;
      await db
          .into(db.zones)
          .insert(
            ZonesCompanion.insert(
              id: newId(),
              propertyId: widget.property.id,
              name: name.trim(),
              geojson: geojson,
              areaAcres: Value(acres),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    // Geometry moved: every record's zone_id is re-derived so the ledger
    // and survival figures stay honest with the new lines.
    await reassignAllZones(db, widget.property.id);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<String?> _askName() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('NAME THE ZONE'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'River strip, North pasture…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
    controller.dispose();
    return name;
  }

  Future<void> _confirmLeave() async {
    if (!_dirty) {
      Navigator.of(context).pop(false);
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('DISCARD CHANGES?'),
        content: const Text('The shape goes back to how it was.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('KEEP EDITING'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('DISCARD'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _confirmLeave,
          ),
          actions: [
            TextButton(
              onPressed: _ring.length >= 3 && _placing == null ? _save : null,
              child: const Text('SAVE'),
            ),
          ],
        ),
        body: Stack(
          children: [
            MapLibreMap(
              trackCameraPosition: true,
              // Let every tap fall through to onMapClick: the default has
              // fills/lines/circles CONSUME taps, which is why tapping a
              // corner reached no callback at all.
              annotationConsumeTapEvents: const [AnnotationType.symbol],
              styleString: basemapStyle(),
              initialCameraPosition: _camera,
              rotateGesturesEnabled: false,
              tiltGesturesEnabled: false,
              onMapCreated: (c) {
                _map = c;
                c.addListener(_onCameraMove);
                c.onCircleTapped.add(_onCircleTap);
              },
              onMapClick: _onMapTap,
              onStyleLoadedCallback: _redraw,
            ),
            Positioned(
              left: Metrics.gutter,
              right: Metrics.gutter,
              top: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                color: Press.ink,
                child: MonoLabel(
                  _ring.length < 3
                      ? 'TAP THREE CORNERS TO START THE SHAPE'
                      : _placing != null
                      ? 'PAN THE MAP UNTIL THE MARK SITS RIGHT · THEN SET'
                            '${_acres.isEmpty ? '' : ' · $_acres'}'
                      : 'TAP A CORNER OR A GHOST TO MOVE IT'
                            '${_acres.isEmpty ? '' : ' · $_acres'}',
                  size: 8.5,
                  spacing: 1.1,
                  color: Press.paperRaised,
                ),
              ),
            ),
            if (_placing != null)
              IgnorePointer(
                child: Center(
                  child: Transform.rotate(
                    angle: 0.7853981633974483,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        border: Border.all(color: Press.oxblood, width: 3),
                        color: Press.oxblood.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: Metrics.gutter,
              right: Metrics.gutter,
              bottom: 16,
              child: _placing != null
                  ? Row(
                      children: [
                        _tool('SET', _setPlaced, color: Press.sage),
                        const SizedBox(width: 8),
                        _tool('CANCEL', _cancelPlacing),
                        const Spacer(),
                        if (!_placingIsNew && _ring.length > 3)
                          _tool(
                            'DELETE POINT',
                            _deletePlacing,
                            color: Press.oxblood,
                          ),
                      ],
                    )
                  : Row(
                      children: [
                        _tool('UNDO', _undo.isEmpty ? null : _undoOnce),
                        const SizedBox(width: 8),
                        _tool('REDO', _redo.isEmpty ? null : _redoOnce),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tool(String label, VoidCallback? onTap, {Color? color}) => SizedBox(
    height: 48,
    child: FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: onTap == null
            ? Press.inkSoft.withValues(alpha: 0.4)
            : (color ?? Press.ink),
      ),
      onPressed: onTap,
      child: Text(label),
    ),
  );
}
