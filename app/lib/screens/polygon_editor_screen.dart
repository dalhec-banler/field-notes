import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../db/database.dart';
import '../export/plate_subject_loader.dart' show acresOf, acresOfRing;
import '../geo/zone_assignment.dart';
import '../map/basemap_style.dart';
import '../services/property_locator.dart';
import '../theme/tokens.dart';
import '../widgets/confirm.dart';
import '../widgets/press.dart';

/// Trace and adjust a polygon on the imagery.
///
/// Rewritten 2026-09-04 (Austin: "the polygon drawing function feels
/// pretty clumsy — are you sure this is a best practice implementation?").
/// It wasn't. The first cut moved corners with a crosshair — tap a corner,
/// wait for the map to fly to it, pan the entire map under a mark, press
/// SET — because maplibre annotation drags lose the gesture to the map's
/// own pan on Android.
///
/// So the handles stopped being annotations. Corners and midpoint ghosts
/// are FLUTTER WIDGETS above the map: Flutter's gesture arena hands a drag
/// straight to the handle, and the map pans only when you touch bare
/// ground. You touch a corner and it follows your thumb — what every
/// mapping app does, and what this always should have.
///
/// Handles are placed by projecting each corner with a pixels-per-degree
/// scale calibrated from the map once per zoom, so there is no per-frame
/// platform round trip; drags move corners by pixel delta, so no
/// coordinate space is converted twice.
class PolygonEditorScreen extends StatefulWidget {
  const PolygonEditorScreen.boundary({
    super.key,
    required this.db,
    required this.property,
    this.initialTarget,
    this.initialZoom,
  }) : zone = null,
       isBoundary = true;

  const PolygonEditorScreen.zone({
    super.key,
    required this.db,
    required this.property,
    required Zone this.zone,
    this.initialTarget,
    this.initialZoom,
  }) : isBoundary = false;

  const PolygonEditorScreen.newZone({
    super.key,
    required this.db,
    required this.property,
    this.initialTarget,
    this.initialZoom,
  }) : zone = null,
       isBoundary = false;

  final FieldNotesDb db;
  final Property property;
  final Zone? zone;
  final bool isBoundary;

  /// Where the map was looking when the editor opened — the editor starts
  /// exactly there. Anything else reads as the map jumping away from the
  /// ground you framed (Austin's bug, 2026-09-04).
  final LatLng? initialTarget;
  final double? initialZoom;

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

  /// The corner under the thumb, and the one tapped (its DELETE shows).
  int? _dragging;
  int? _selected;

  /// Decided ONCE at open. A getter that recomputed the camera from the
  /// ring made the map fight the user: every pan changed the ring, which
  /// changed the camera, which snapped the map back — the bounce.
  late final CameraPosition _initialCamera = _decideCamera();
  LatLng? _camTarget;
  double _camZoom = 15;

  /// Logical pixels per degree at this zoom, calibrated from the map.
  double? _pxPerLng;
  double? _pxPerLat;
  double _calibratedAtZoom = -1;

  bool get _dirty => _undo.isNotEmpty;

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

  CameraPosition _decideCamera() {
    // Where the map was looking wins: that is the ground the user framed.
    final target = widget.initialTarget;
    if (target != null) {
      return CameraPosition(target: target, zoom: widget.initialZoom ?? 16);
    }
    if (_ring.isNotEmpty) {
      return CameraPosition(target: _ringCentre, zoom: 15.5);
    }
    // A place that has never been located: open on its centroid if it has
    // one, else on the whole country and let the user find their ground.
    final p = widget.property;
    if (p.centroidLat != null && p.centroidLng != null) {
      return CameraPosition(
        target: LatLng(p.centroidLat!, p.centroidLng!),
        zoom: 15,
      );
    }
    return const CameraPosition(target: LatLng(39.5, -98.35), zoom: 3);
  }

  LatLng get _ringCentre {
    var lat = 0.0, lng = 0.0;
    for (final p in _ring) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / _ring.length, lng / _ring.length);
  }

  LatLng _midOf(int i) {
    final a = _ring[i];
    final b = _ring[(i + 1) % _ring.length];
    return LatLng(
      (a.latitude + b.latitude) / 2,
      (a.longitude + b.longitude) / 2,
    );
  }

  String get _acres {
    if (_ring.length < 3) return '';
    final a = acresOfRing([
      for (final p in _ring) [p.longitude, p.latitude],
    ]);
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
  }

  // ── camera mirror + projection ───────────────────────────────────

  void _onCameraMove() {
    final pos = _map?.cameraPosition;
    if (pos == null || !mounted) return;
    final zoomChanged = (pos.zoom - _calibratedAtZoom).abs() > 0.01;
    setState(() {
      _camTarget = pos.target;
      _camZoom = pos.zoom;
    });
    if (zoomChanged) _calibrate();
  }

  /// Ask the map what a degree is worth in pixels here. One round trip per
  /// zoom level; every handle after that is placed with arithmetic.
  Future<void> _calibrate() async {
    final map = _map;
    if (map == null) return;
    final target = _camTarget ?? _initialCamera.target;
    final zoom = _camZoom;
    try {
      const d = 0.002; // ~200 m: big enough to swamp rounding
      final a = await map.toScreenLocation(target);
      final b = await map.toScreenLocation(
        LatLng(target.latitude + d, target.longitude + d),
      );
      if (!mounted) return;
      // toScreenLocation answers in DEVICE pixels; widgets live in logical
      // ones — the same difference that bit the map screen's hit-testing.
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final perLng = ((b.x - a.x) / d).abs() / dpr;
      final perLat = ((a.y - b.y) / d).abs() / dpr;
      if (perLng.isFinite && perLat.isFinite && perLng > 0 && perLat > 0) {
        setState(() {
          _pxPerLng = perLng;
          _pxPerLat = perLat;
          _calibratedAtZoom = zoom;
        });
      }
    } catch (_) {
      // A failed calibration just means the handles wait a frame.
    }
  }

  /// Where a coordinate sits on screen, in logical pixels.
  Offset? _screenOf(LatLng p, Size size) {
    final t = _camTarget ?? _initialCamera.target;
    final perLng = _pxPerLng;
    final perLat = _pxPerLat;
    if (perLng == null || perLat == null) return null;
    return Offset(
      size.width / 2 + (p.longitude - t.longitude) * perLng,
      size.height / 2 - (p.latitude - t.latitude) * perLat,
    );
  }

  // ── geometry (fill + outline only; the handles are widgets) ───────

  Future<void> _redraw() async {
    final map = _map;
    if (map == null) return;
    try {
      await map.clearFills();
      await map.clearLines();
    } catch (_) {}
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
    if (mounted) setState(() {});
  }

  bool _geomBusy = false;

  /// Live outline while a corner is under the thumb; a frame that lands
  /// mid-update is dropped and the next one carries the truth.
  Future<void> _liveGeometry() async {
    final map = _map;
    if (map == null || _geomBusy) return;
    _geomBusy = true;
    try {
      final ringClosed = [..._ring, if (_ring.isNotEmpty) _ring.first];
      if (_fill != null && _ring.length >= 3) {
        await map.updateFill(_fill!, FillOptions(geometry: [ringClosed]));
      }
      if (_outline != null && _ring.length >= 2) {
        await map.updateLine(_outline!, LineOptions(geometry: ringClosed));
      }
    } catch (_) {
    } finally {
      _geomBusy = false;
    }
  }

  // ── editing ──────────────────────────────────────────────────────

  /// Tap on bare map: the first three corners are laid down by tapping.
  Future<void> _onMapTap(dynamic point, LatLng latLng) async {
    if (_ring.length < 3) {
      _snapshot();
      setState(() => _ring.add(latLng));
      await _redraw();
      return;
    }
    if (_selected != null) setState(() => _selected = null);
  }

  /// Move the dragged corner by a pixel delta — direct manipulation, no
  /// coordinate space converted twice.
  void _dragBy(Offset delta) {
    final i = _dragging;
    final perLng = _pxPerLng;
    final perLat = _pxPerLat;
    if (i == null || i >= _ring.length || perLng == null || perLat == null) {
      return;
    }
    final p = _ring[i];
    setState(() {
      _ring[i] = LatLng(
        p.latitude - delta.dy / perLat,
        p.longitude + delta.dx / perLng,
      );
    });
    _liveGeometry();
  }

  /// Grabbing a ghost turns it into a real corner, already under the thumb.
  void _grabMidpoint(int segment) {
    _snapshot();
    final at = segment + 1;
    setState(() {
      _ring.insert(at, _midOf(segment));
      _dragging = at;
      _selected = at;
    });
    _redraw();
  }

  Future<void> _deleteSelected() async {
    final i = _selected;
    if (i == null || _ring.length <= 3) return;
    _snapshot();
    setState(() {
      _ring.removeAt(i);
      _selected = null;
    });
    await _redraw();
  }

  void _undoOnce() {
    if (_undo.isEmpty) return;
    _redo.add(List.of(_ring));
    setState(() {
      _ring
        ..clear()
        ..addAll(_undo.removeLast());
      _selected = null;
    });
    _redraw();
  }

  void _redoOnce() {
    if (_redo.isEmpty) return;
    _undo.add(List.of(_ring));
    setState(() {
      _ring
        ..clear()
        ..addAll(_redo.removeLast());
      _selected = null;
    });
    _redraw();
  }

  Future<void> _save() async {
    if (_ring.length < 3) return;
    final db = widget.db;
    final now = nowUtcIso();
    final geojson = _ringGeojson();
    final acres = acresOf(geojson);
    if (widget.isBoundary) {
      final centre = _ringCentre;
      await (db.update(
        db.properties,
      )..where((p) => p.id.equals(widget.property.id))).write(
        PropertiesCompanion(
          boundaryGeojson: Value(geojson),
          centroidLat: Value(centre.latitude),
          centroidLng: Value(centre.longitude),
          acreage: Value(acres),
          updatedAt: Value(now),
        ),
      );
      await PropertyLocator(db).noteLocation(
        widget.property.id,
        centre.latitude,
        centre.longitude,
        setCentroid: false,
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
    final leave = await confirmDialog(
      context,
      title: 'DISCARD CHANGES?',
      body: 'The shape goes back to how it was.',
      cancelLabel: 'KEEP EDITING',
      confirmLabel: 'DISCARD',
    );
    if (leave && mounted) Navigator.of(context).pop(false);
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
        body: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              children: [
                MapLibreMap(
                  trackCameraPosition: true,
                  styleString: basemapStyle(),
                  initialCameraPosition: _initialCamera,
                  rotateGesturesEnabled: false,
                  tiltGesturesEnabled: false,
                  onMapCreated: (c) {
                    _map = c;
                    c.addListener(_onCameraMove);
                  },
                  onMapClick: _onMapTap,
                  onStyleLoadedCallback: () async {
                    await _redraw();
                    await _calibrate();
                  },
                ),

                // Midpoint ghosts, under the corners: grab one and it
                // becomes a real corner already following your thumb.
                if (_ring.length >= 2)
                  for (var i = 0; i < _ring.length; i++)
                    if (!(_ring.length == 2 && i == 1))
                      _handle(
                        key: ValueKey('mid-$i'),
                        at: _screenOf(_midOf(i), size),
                        box: 34,
                        onPanStart: () => _grabMidpoint(i),
                        onPanUpdate: _dragBy,
                        onTap: () => _grabMidpoint(i),
                        child: _ghostDot(),
                      ),

                // Corners: touch and drag. No fly, no crosshair, no SET.
                for (var i = 0; i < _ring.length; i++)
                  _handle(
                    key: ValueKey('corner-$i'),
                    at: _screenOf(_ring[i], size),
                    box: 46,
                    onPanStart: () {
                      _snapshot();
                      setState(() {
                        _dragging = i;
                        _selected = i;
                      });
                    },
                    onPanUpdate: _dragBy,
                    onTap: () =>
                        setState(() => _selected = _selected == i ? null : i),
                    child: _cornerDot(i == _selected),
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
                          : 'DRAG A CORNER TO MOVE IT · DRAG A GHOST TO ADD ONE'
                                '${_acres.isEmpty ? '' : ' · $_acres'}',
                      size: 8.5,
                      spacing: 1.1,
                      color: Press.paperRaised,
                      maxLines: 2,
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
                      if (_selected != null && _ring.length > 3)
                        _tool(
                          'DELETE POINT',
                          _deleteSelected,
                          color: Press.oxblood,
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// A draggable handle above the map. Gestures land here, not on the
  /// platform view, so the map holds still while a corner moves.
  Widget _handle({
    required Key key,
    required Offset? at,
    required double box,
    required VoidCallback onPanStart,
    required void Function(Offset delta) onPanUpdate,
    required VoidCallback onTap,
    required Widget child,
  }) {
    if (at == null) return SizedBox.shrink(key: key);
    return Positioned(
      key: key,
      left: at.dx - box / 2,
      top: at.dy - box / 2,
      width: box,
      height: box,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onPanStart: (_) => onPanStart(),
        onPanUpdate: (d) => onPanUpdate(d.delta),
        onPanEnd: (_) {
          setState(() => _dragging = null);
          _redraw();
        },
        child: Center(child: child),
      ),
    );
  }

  Widget _cornerDot(bool selected) => Container(
    width: 22,
    height: 22,
    decoration: BoxDecoration(
      color: selected ? Press.oxblood : const Color(0xFFF7F6F2),
      shape: BoxShape.circle,
      border: Border.all(color: Press.oxblood, width: 3),
      boxShadow: const [
        BoxShadow(
          color: Color(0x40000000),
          blurRadius: 3,
          offset: Offset(0, 1),
        ),
      ],
    ),
  );

  Widget _ghostDot() => Container(
    width: 15,
    height: 15,
    decoration: BoxDecoration(
      color: const Color(0x99F7F6F2),
      shape: BoxShape.circle,
      border: Border.all(color: Press.oxblood, width: 1.5),
    ),
  );

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
