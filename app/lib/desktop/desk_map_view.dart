import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:drift/drift.dart' hide Column;

import '../db/database.dart';
import '../export/map_plate.dart';
import '../export/web_mercator.dart' as merc;
import '../map/cluster_badge.dart';
import '../map/imagery_sources.dart';
import '../map/layers/layer_loader.dart';
import '../map/layers/map_layers.dart';
import '../map/record_clusters.dart';
import '../map/record_ink.dart';
import '../map/tile_cache.dart';
import '../screens/record_detail_screen.dart';
import '../services/diag.dart';
import '../services/map_jump.dart';
import '../theme/tokens.dart';
import '../widgets/confirm.dart';
import '../widgets/press.dart';

part 'desk_map_view/core.dart';
part 'desk_map_view/tiles.dart';
part 'desk_map_view/marks.dart';
part 'desk_map_view/panels.dart';
part 'desk_map_view/painter.dart';

/// The desk's map (Austin, 2026-09-03: "critically important").
///
/// maplibre_gl has no desktop platform, so this is our own slippy map on
/// the machinery the plate already proved: web-mercator math, XYZ imagery
/// tiles, and the shared record mark language. Drag to pan, scroll or
/// double-click to zoom, click a mark to open the record. What it draws
/// is the one [MapLayerSet] (D-038 item 11); this file owns only how a
/// layer paints on a Canvas.
///
/// Beside it, the species panel (Austin's design, same day): every species
/// on this map listed on the right; click one and its card opens in place
/// — pushing the others down — while its marks light up on the map and
/// everything else dims. Eradication sweeps and population reads at a
/// glance.
class DeskMapWorkspace extends StatefulWidget {
  const DeskMapWorkspace({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<DeskMapWorkspace> createState() => _DeskMapWorkspaceState();
}

/// One row of the panel: every record sharing a species label (or, for
/// unnamed records, sharing a type).
class _SpeciesGroup {
  _SpeciesGroup(this.key, this.label, this.type, this.records);
  final String key;
  final String label;
  final String type;
  final List<MapRecord> records;

  RecordRealm get realm =>
      records.first.label != null ? RecordRealm.species : realmOfType(type);

  /// D-027 for the row: red while any of these is flagged, ink once every
  /// one of them is out, nothing while the group is simply growing.
  String? get removal {
    if (records.any((r) => r.removal == 'flagged')) return 'flagged';
    if (records.every((r) => r.removal == 'removed')) return 'removed';
    return null;
  }
}

/// Split along its concerns (D-038 item 7): state in `desk_map_view/
/// core.dart`, imagery in `tiles.dart`, clustering and hit-testing in
/// `marks.dart`, the side panels in `panels.dart`, the canvas painter in
/// `painter.dart`. Lifecycle, build and the map itself stay here.
class _DeskMapWorkspaceState extends State<DeskMapWorkspace>
    with _DeskMapCore, _DeskMapTiles, _DeskMapMarks, _DeskMapPanels {
  @override
  void initState() {
    super.initState();
    mapJump.addListener(_onMapJump);
    // The watch emits once on listen, so it is also the first load — and
    // that load frames, since nothing has moved the camera yet. The
    // feature panel's condition log is here too: a fresh layer set is
    // what re-reads an open panel.
    _watch = widget.db
        .changes({..._loader.tables, widget.db.featureConditionLogs})
        .listen((_) => _load());
  }

  @override
  void dispose() {
    mapJump.removeListener(_onMapJump);
    _watch?.cancel();
    for (final img in _images.values) {
      img.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final s = await _loader.load(widget.property);
    if (!mounted) return;
    setState(() => _layers = s);
    if (_lat == null) _frameSubject(s, _lastLayoutSize);
    _onMapJump();
  }

  /// A jump for this place (D-029): fly there and light the record, taken
  /// on the notifier firing or on the first load after a place switch.
  void _onMapJump() {
    final j = mapJump.value;
    if (j == null || j.propertyId != widget.property.id) return;
    if (_layers == null) return; // the load that follows takes it
    mapJump.value = null;
    setState(() => _selectedId = j.recordId);
    _flyTo(j.lat, j.lng, zoom: activeImagery.maxZoom - 0.5);
  }

  /// The camera's opening question is "where are my marks?" — records
  /// first, then whatever geometry the place has.
  void _frameSubject(MapLayerSet s, Size size) {
    var b = merc.LatLngBounds.ofPoints([
      for (final r in s.records) (r.lat, r.lng),
    ]);
    b ??= MapPlate.frameBounds(PlateSubject.of(s), const PlateLayers());
    final bb = b.pad(0.25);
    setState(() {
      _lat = (bb.north + bb.south) / 2;
      _lng = (bb.east + bb.west) / 2;
      _zoom = merc
          .zoomFor(bb, size.width, size.height, maxZoom: activeImagery.maxZoom)
          .toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    _dprBoost = MediaQuery.of(context).devicePixelRatio >= 1.5 ? 1 : 0;
    final s = _layers;
    if (s == null || _lat == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _map(s)),
        Container(
          width: 380,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: Press.borderInk, width: 1.5),
            ),
          ),
          child: _selectedFeatureId != null
              ? _featurePanel(_selectedFeatureId!)
              : _selectedId == null
              ? _speciesPanel(s)
              : _recordPanel(),
        ),
      ],
    );
  }

  Widget _map(MapLayerSet s) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _syncImagerySource();
        _lastLayoutSize = size;
        if (!_sizedFrame) {
          _sizedFrame = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _layers != null && !_userMoved) {
              _frameSubject(_layers!, size);
            }
          });
        }
        _ensureVisibleTiles(size);
        final (lit, dimmed) = _clustersFor(s);
        return ClipRect(
          child: Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                _zoomBy(
                  e.scrollDelta.dy > 0 ? -0.5 : 0.5,
                  e.localPosition,
                  size,
                );
              }
            },
            // A Mac trackpad never sends PointerScrollEvent: two-finger
            // scroll and pinch arrive as pan-zoom events. The drag
            // recognizer already turns the scroll into a pan; the pinch's
            // scale was going nowhere — "only panning works" (Austin,
            // 2026-09-04). Zoom by the change in cumulative scale, anchored
            // on the fingers.
            onPointerPanZoomStart: (e) => _panZoomScale = 1.0,
            onPointerPanZoomUpdate: (e) {
              if (e.scale <= 0) return;
              final dz = math.log(e.scale / _panZoomScale) / math.ln2;
              if (dz.abs() > 0.001) {
                _zoomBy(dz, e.localPosition, size);
                _panZoomScale = e.scale;
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => _panBy(d.delta, size),
              onDoubleTapDown: (d) => _zoomBy(1, d.localPosition, size),
              onTapUp: (d) => _onTapUp(d, size),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _DeskMapPainter(
                      layers: s,
                      lit: lit,
                      dimmed: dimmed,
                      images: _images,
                      zInt: _zInt,
                      tileScale: _tileScale,
                      centre: _worldPx(_lat!, _lng!),
                      selectedId: _selectedId,
                      highlightKey: _highlightKey,
                      screenOf: _screenOf,
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 6,
                    child: Container(
                      color: const Color(0xCCF7F6F2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: MonoLabel(
                        '${activeImagery.attribution} · z${_zoom.toStringAsFixed(1)}',
                        size: 8,
                        color: const Color(0xFF1B1813),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    top: 8,
                    child: Container(
                      color: Press.ink,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: MonoLabel(
                        'DRAG TO PAN · SCROLL TO ZOOM · CLICK A MARK '
                        'TO OPEN THE RECORD',
                        size: 8,
                        spacing: 1.2,
                        color: Press.paperRaised,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    top: 40,
                    child: InkWell(
                      onTap: _gotoCoords,
                      child: Container(
                        color: Press.ink,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: MonoLabel(
                          '⌖ GO TO…',
                          size: 8,
                          spacing: 1.2,
                          color: Press.paperRaised,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: InkWell(
                      onTap: () {
                        _userMoved = false;
                        final s2 = _layers;
                        if (s2 != null) {
                          _frameSubject(s2, _lastLayoutSize);
                        }
                      },
                      child: Container(
                        color: Press.ink,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: MonoLabel(
                          '⌖ FIT MARKS',
                          size: 8,
                          spacing: 1.2,
                          color: Press.paperRaised,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
