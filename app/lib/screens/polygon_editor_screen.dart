import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../db/database.dart';
import '../export/plate_subject_loader.dart' show acresOf;
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
  }) : zone = null,
       isBoundary = true;

  const PolygonEditorScreen.zone({
    super.key,
    required this.db,
    required this.property,
    required Zone this.zone,
  }) : isBoundary = false;

  const PolygonEditorScreen.newZone({
    super.key,
    required this.db,
    required this.property,
  }) : zone = null,
       isBoundary = false;

  final FieldNotesDb db;
  final Property property;
  final Zone? zone;
  final bool isBoundary;

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
  bool _dragSnapshotTaken = false;

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
      target: c == null ? const LatLng(31.06, -98.05) : LatLng(c[1], c[0]),
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
    // Wipe and rebuild — the counts here are tens, not thousands.
    for (final c in _circles) {
      try {
        await map.removeCircle(c);
      } catch (_) {}
    }
    _circles.clear();
    _vertexIdx.clear();
    _midIdx.clear();

    final ringClosed = _ring.length >= 3
        ? [..._ring, _ring.first]
        : List.of(_ring);
    if (_fill != null) {
      try {
        await map.removeFill(_fill!);
      } catch (_) {}
      _fill = null;
    }
    if (_outline != null) {
      try {
        await map.removeLine(_outline!);
      } catch (_) {}
      _outline = null;
    }
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
            draggable: true,
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
          draggable: true,
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

  void _onDrag(
    dynamic point,
    LatLng origin,
    LatLng current,
    LatLng delta,
    dynamic id,
    dynamic annotation,
    DragEventType eventType,
  ) {
    final vertex = _vertexIdx[id];
    final midAt = _midIdx[id];
    if (vertex == null && midAt == null) return;
    if (eventType == DragEventType.start) {
      _dragSnapshotTaken = false;
      return;
    }
    if (!_dragSnapshotTaken) {
      _snapshot();
      _dragSnapshotTaken = true;
      if (midAt != null) {
        // The ghost becomes a real corner and keeps following the finger.
        _ring.insert(midAt, current);
        _vertexIdx[id as String] = midAt;
        _midIdx.remove(id);
      }
    }
    final i = _vertexIdx[id];
    if (i == null || i >= _ring.length) return;
    _ring[i] = current;
    _liveGeometry();
    if (eventType == DragEventType.end) {
      _selected = null;
      _redraw();
    } else if (mounted) {
      setState(() {}); // acreage readout follows the drag
    }
  }

  void _onMapTap(dynamic point, LatLng latLng) {
    // Building a new shape: every tap is a corner until there are three.
    if (_ring.length < 3) {
      _snapshot();
      _ring.add(latLng);
      _redraw();
      return;
    }
    if (_selected != null) {
      setState(() => _selected = null);
      _redraw();
    }
  }

  void _onCircleTap(Circle circle) {
    final i = _vertexIdx[circle.id];
    if (i == null) return;
    setState(() => _selected = _selected == i ? null : i);
    _redraw();
  }

  void _deleteSelected() {
    final i = _selected;
    if (i == null || _ring.length <= 3) return;
    _snapshot();
    _ring.removeAt(i);
    _selected = null;
    _redraw();
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
              onPressed: _ring.length >= 3 ? _save : null,
              child: const Text('SAVE'),
            ),
          ],
        ),
        body: Stack(
          children: [
            MapLibreMap(
              styleString: basemapStyle(),
              initialCameraPosition: _camera,
              rotateGesturesEnabled: false,
              tiltGesturesEnabled: false,
              onMapCreated: (c) {
                _map = c;
                c.onFeatureDrag.add(_onDrag);
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
                      : 'DRAG A CORNER · DRAG A GHOST TO ADD ONE · '
                            'TAP A CORNER TO SELECT${_acres.isEmpty ? '' : ' · $_acres'}',
                  size: 8.5,
                  spacing: 1.1,
                  color: Press.paperRaised,
                ),
              ),
            ),
            Positioned(
              left: Metrics.gutter,
              right: Metrics.gutter,
              bottom: 16,
              child: Row(
                children: [
                  _tool('UNDO', _undo.isEmpty ? null : _undoOnce),
                  const SizedBox(width: 8),
                  _tool('REDO', _redo.isEmpty ? null : _redoOnce),
                  const Spacer(),
                  if (_selected != null)
                    _tool(
                      'DELETE POINT',
                      _ring.length > 3 ? _deleteSelected : null,
                      color: Press.oxblood,
                    ),
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
