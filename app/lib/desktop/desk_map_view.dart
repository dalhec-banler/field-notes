import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../export/map_plate.dart';
import '../export/plate_subject_loader.dart';
import '../export/web_mercator.dart' as merc;
import '../map/imagery_sources.dart';
import '../map/record_ink.dart';
import '../map/tile_cache.dart';
import '../screens/record_detail_screen.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// The desk's map (Austin, 2026-09-03: "critically important").
///
/// maplibre_gl has no desktop platform, so this is our own slippy map on
/// the machinery the plate already proved: web-mercator math, XYZ imagery
/// tiles, and the shared record mark language. Drag to pan, scroll or
/// double-click to zoom, click a mark to open the record.
///
/// Beside it, the species panel (Austin's design, same day): every species
/// on this map listed on the right; click one and its card opens in place
/// — pushing the others down — while its marks light up on the map and
/// everything else dims. Eradication sweeps and population reads at a
/// glance.
class DeskMapWorkspace extends StatefulWidget {
  DeskMapWorkspace({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<DeskMapWorkspace> createState() => _DeskMapWorkspaceState();
}

/// One row of the species panel: every record sharing a species label
/// (or, for unnamed records, sharing a type).
class _SpeciesGroup {
  _SpeciesGroup(this.key, this.label, this.type, this.records);
  final String key;
  final String label;
  final String type;
  final List<PlateRecord> records;
}

class _DeskMapWorkspaceState extends State<DeskMapWorkspace> {
  PlateSubject? _subject;
  String? _selectedId;

  /// The species group lit on the map and opened in the panel.
  String? _highlightKey;
  StreamSubscription<void>? _watch;

  // Camera.
  double? _lat, _lng;
  double _zoom = 15;

  // Tiles: bytes are LRU-cached across the session; decoded images live
  // for this view. A fetch in flight is never issued twice.
  final _tiles = TileCache();
  late TileFetcher _fetch = _buildFetcher();
  final _images = <String, ui.Image>{};
  final _inflight = <String>{};
  final _missing = <String>{};
  String _fetchSourceId = activeImagery.id;
  int _tileEpoch = 0;

  TileFetcher _buildFetcher() {
    final primary = httpTileFetcher(template: activeImagery.template);
    final chained = activeImagery.id == 'usgs'
        ? primary
        : tileFetcherWithFallback(primary, httpTileFetcher());
    return _tiles.wrap(chained);
  }

  /// Settings can swap the imagery source while this map lives: rebuild
  /// the fetcher, drop every cached tile, and let in-flight fetches from
  /// the old source die on arrival.
  void _syncImagerySource() {
    if (_fetchSourceId == activeImagery.id) return;
    _fetchSourceId = activeImagery.id;
    _tileEpoch++;
    _fetch = _buildFetcher();
    _tiles.clear();
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    _inflight.clear();
    _missing.clear();
  }

  @override
  void initState() {
    super.initState();
    _load(frame: true);
    _watch = widget.db
        .customSelect(
          'SELECT 1',
          readsFrom: {
            widget.db.observations,
            widget.db.zones,
            widget.db.features,
            widget.db.tracks,
            widget.db.properties,
          },
        )
        .watch()
        .listen((_) => _load());
  }

  @override
  void dispose() {
    _watch?.cancel();
    for (final img in _images.values) {
      img.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool frame = false}) async {
    final s = await loadPlateSubject(widget.db, widget.property);
    if (!mounted) return;
    setState(() => _subject = s);
    if (frame || _lat == null) _frameSubject(s, _lastLayoutSize);
  }

  /// The camera's opening question is "where are my marks?" — records
  /// first, then whatever geometry the place has.
  void _frameSubject(PlateSubject s, Size size) {
    var b = merc.LatLngBounds.ofPoints([
      for (final r in s.records) (r.lat, r.lng),
    ]);
    b ??= MapPlate.frameBounds(s, const PlateLayers());
    final bb = b.pad(0.25);
    setState(() {
      _lat = (bb.north + bb.south) / 2;
      _lng = (bb.east + bb.west) / 2;
      _zoom = merc
          .zoomFor(bb, size.width, size.height, maxZoom: activeImagery.maxZoom)
          .toDouble();
    });
  }

  Size _lastLayoutSize = const Size(900, 700);
  bool _sizedFrame = false;
  bool _userMoved = false;

  // ── camera math ──────────────────────────────────────────────────

  int get _zInt => _zoom.floor().clamp(3, activeImagery.maxZoom);
  double get _tileScale => math.pow(2.0, _zoom - _zInt).toDouble();

  (double, double) _worldPx(double lat, double lng) {
    final (x, y) = merc.project(lat, lng, _zInt);
    return (x * _tileScale, y * _tileScale);
  }

  (double, double) _screenOf(double lat, double lng, Size size) {
    final (cx, cy) = _worldPx(_lat!, _lng!);
    final (x, y) = _worldPx(lat, lng);
    return (x - cx + size.width / 2, y - cy + size.height / 2);
  }

  /// Shift what's on screen by [delta] pixels (drag semantics: content
  /// follows the pointer).
  void _panBy(Offset delta, Size size) {
    _userMoved = true;
    final (cx, cy) = _worldPx(_lat!, _lng!);
    final nx = cx - delta.dx;
    final ny = cy - delta.dy;
    final (lat, lng) = merc.unproject(nx / _tileScale, ny / _tileScale, _zInt);
    setState(() {
      _lat = lat.clamp(-84.0, 84.0);
      _lng = lng;
    });
  }

  void _zoomBy(double dz, Offset about, Size size) {
    _userMoved = true;
    // Anchor the zoom on the CURSOR: the coordinate under it must stay
    // under it. The first cut re-centred that point to the window middle,
    // so successive scrolls dragged the camera across town (Austin,
    // 2026-09-03).
    final aLatLng = _latLngAt(about, size);
    setState(() {
      _zoom = (_zoom + dz).clamp(4.0, activeImagery.maxZoom + 0.99);
    });
    final (ax, ay) = _screenOf(aLatLng.$1, aLatLng.$2, size);
    _panBy(Offset(about.dx - ax, about.dy - ay), size);
  }

  (double, double) _latLngAt(Offset p, Size size) {
    final (cx, cy) = _worldPx(_lat!, _lng!);
    final wx = cx + (p.dx - size.width / 2);
    final wy = cy + (p.dy - size.height / 2);
    return merc.unproject(wx / _tileScale, wy / _tileScale, _zInt);
  }

  // ── tiles ────────────────────────────────────────────────────────

  void _ensureVisibleTiles(Size size) {
    final z = _zInt;
    final n = 1 << z;
    final (cx, cy) = _worldPx(_lat!, _lng!);
    final drawn = merc.tileSize * _tileScale;
    final left = ((cx - size.width / 2) / drawn).floor();
    final top = ((cy - size.height / 2) / drawn).floor();
    final right = ((cx + size.width / 2) / drawn).floor();
    final bottom = ((cy + size.height / 2) / drawn).floor();
    for (var ty = top; ty <= bottom; ty++) {
      for (var tx = left; tx <= right; tx++) {
        if (tx < 0 || ty < 0 || tx >= n || ty >= n) continue;
        final key = '$z/$tx/$ty';
        if (_images.containsKey(key) ||
            _inflight.contains(key) ||
            _missing.contains(key)) {
          continue;
        }
        _inflight.add(key);
        final epoch = _tileEpoch;
        _fetch(z, tx, ty).then((bytes) async {
          if (epoch != _tileEpoch) return; // source swapped mid-flight
          _inflight.remove(key);
          if (bytes == null) {
            _missing.add(key);
            return;
          }
          try {
            final codec = await ui.instantiateImageCodec(bytes);
            final img = (await codec.getNextFrame()).image;
            codec.dispose();
            if (!mounted || epoch != _tileEpoch) {
              img.dispose();
              return;
            }
            setState(() => _images[key] = img);
          } catch (_) {
            _missing.add(key);
          }
        });
      }
    }
  }

  // ── species groups ───────────────────────────────────────────────

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  List<_SpeciesGroup> get _groups {
    final s = _subject;
    if (s == null) return const [];
    final byKey = <String, _SpeciesGroup>{};
    for (final r in s.records) {
      final key = r.label ?? '__type:${r.type}';
      (byKey[key] ??= _SpeciesGroup(
        key,
        r.label ?? '${_cap(r.type)} — unnamed',
        r.type,
        [],
      )).records.add(r);
    }
    final out = byKey.values.toList()
      ..sort((a, b) {
        final byCount = b.records.length.compareTo(a.records.length);
        return byCount != 0
            ? byCount
            : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    return out;
  }

  // ── hit test ─────────────────────────────────────────────────────

  void _onTapUp(TapUpDetails d, Size size) {
    final s = _subject;
    if (s == null) return;
    String? best;
    var bestD = 16.0; // px
    for (final r in s.records) {
      if (r.id == null) continue;
      final (x, y) = _screenOf(r.lat, r.lng, size);
      final dist = (Offset(x, y) - d.localPosition).distance;
      if (dist < bestD) {
        bestD = dist;
        best = r.id;
      }
    }
    if (best != null) setState(() => _selectedId = best);
  }

  @override
  Widget build(BuildContext context) {
    final s = _subject;
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
          child: _selectedId == null ? _speciesPanel(s) : _recordPanel(),
        ),
      ],
    );
  }

  Widget _map(PlateSubject s) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _syncImagerySource();
        _lastLayoutSize = size;
        if (!_sizedFrame) {
          _sizedFrame = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _subject != null && !_userMoved) {
              _frameSubject(_subject!, size);
            }
          });
        }
        _ensureVisibleTiles(size);
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
                      subject: s,
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
                    top: 8,
                    child: InkWell(
                      onTap: () {
                        _userMoved = false;
                        final s2 = _subject;
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

  /// The species panel: what lives on this map, most-seen first. Click a
  /// species — its card opens in place, everything else slides down, and
  /// its marks light up while the rest of the map dims.
  Widget _speciesPanel(PlateSubject s) {
    final groups = _groups;
    if (groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No records on this map yet. The phone captures; this desk '
            'reviews them in place.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 14.5,
              height: 1.5,
              color: Press.inkSoft,
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Kicker('On this map'),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    'SPECIES',
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w900,
                      fontSize: 22,
                      height: 0.9,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${groups.length}',
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w900,
                      fontSize: 22,
                      color: Press.oxblood,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(children: [for (final g in groups) _speciesRow(g)]),
        ),
      ],
    );
  }

  Widget _speciesRow(_SpeciesGroup g) {
    final open = g.key == _highlightKey;
    final dates =
        g.records.map((r) => r.observedAt).whereType<String>().toList()..sort();
    String day(String iso) => iso.length >= 10 ? iso.substring(0, 10) : iso;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _highlightKey = open ? null : g.key),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: open ? Press.paperRaised : null,
              border: Border(
                bottom: BorderSide(color: Press.divider, width: 1),
                left: BorderSide(
                  color: open ? Press.oxblood : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Row(
              children: [
                _MarkSwatch(type: g.type),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    g.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: Type.serif,
                      fontSize: 15.5,
                      fontStyle: g.records.first.label != null
                          ? FontStyle.italic
                          : FontStyle.normal,
                      color: Press.ink,
                    ),
                  ),
                ),
                MonoLabel('${g.records.length}', size: 10, opacity: 0.7),
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: Press.inkSoft,
                ),
              ],
            ),
          ),
        ),
        if (open)
          Container(
            color: Press.paperRaised,
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Press.paper,
                    border: Border.all(color: Press.borderInk, width: 1.5),
                  ),
                  child: Column(
                    children: [
                      FactRow(
                        'seen here',
                        '${g.records.length} time'
                            '${g.records.length == 1 ? '' : 's'}',
                      ),
                      FactRow('first', dates.isEmpty ? '—' : day(dates.first)),
                      FactRow(
                        'last',
                        dates.isEmpty ? '—' : day(dates.last),
                        last: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                for (final r in g.records)
                  if (r.id != null)
                    InkWell(
                      onTap: () => setState(() => _selectedId = r.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            Diamond(
                              size: 8,
                              color: Color(markFor(r.type).argb),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                r.observedAt == null
                                    ? _cap(r.type)
                                    : '${day(r.observedAt!)} · ${r.type}',
                                style: TextStyle(
                                  fontFamily: Type.serif,
                                  fontSize: 13.5,
                                  color: Press.ink,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: Press.inkSoft,
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
      ],
    );
  }

  /// A clicked mark's record, with the way back to the species list.
  Widget _recordPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _selectedId = null),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Press.borderInk, width: 1.5),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.chevron_left, size: 18, color: Press.inkSoft),
                const SizedBox(width: 4),
                MonoLabel('SPECIES LIST', size: 9, spacing: 1.6),
              ],
            ),
          ),
        ),
        Expanded(
          child: RecordDetailScreen(
            key: ValueKey(_selectedId),
            db: widget.db,
            obsId: _selectedId!,
            embedded: true,
          ),
        ),
      ],
    );
  }
}

/// The mark swatch beside a species row — same shape language as the map.
class _MarkSwatch extends StatelessWidget {
  const _MarkSwatch({required this.type});
  final String type;

  @override
  Widget build(BuildContext context) {
    final mark = markFor(type);
    final color = Color(mark.argb);
    return switch (mark.shape) {
      RecordShape.circle => Container(
        width: 13,
        height: 13,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFECE3CE), width: 1.5),
        ),
      ),
      RecordShape.square => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: const Color(0xFFECE3CE), width: 1.5),
        ),
      ),
      RecordShape.triangle => CustomPaint(
        size: const Size(14, 13),
        painter: _TriPainter(color),
      ),
    };
  }
}

class _TriPainter extends CustomPainter {
  _TriPainter(this.color);
  final Color color;

  @override
  void paint(ui.Canvas canvas, Size size) {
    final tri = ui.Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      tri,
      ui.Paint()
        ..color = const Color(0xFFECE3CE)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = ui.StrokeJoin.round,
    );
    canvas.drawPath(tri, ui.Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TriPainter old) => old.color != color;
}

class _DeskMapPainter extends CustomPainter {
  _DeskMapPainter({
    required this.subject,
    required this.images,
    required this.zInt,
    required this.tileScale,
    required this.centre,
    required this.selectedId,
    required this.highlightKey,
    required this.screenOf,
  });

  final PlateSubject subject;
  final Map<String, ui.Image> images;
  final int zInt;
  final double tileScale;
  final (double, double) centre;
  final String? selectedId;
  final String? highlightKey;
  final (double, double) Function(double lat, double lng, Size size) screenOf;

  @override
  void paint(ui.Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFFE8E6DF),
    );
    final (cx, cy) = centre;
    final drawnTile = merc.tileSize * tileScale;
    final left = ((cx - size.width / 2) / drawnTile).floor();
    final top = ((cy - size.height / 2) / drawnTile).floor();
    final right = ((cx + size.width / 2) / drawnTile).floor();
    final bottom = ((cy + size.height / 2) / drawnTile).floor();
    for (var ty = top; ty <= bottom; ty++) {
      for (var tx = left; tx <= right; tx++) {
        final img = images['$zInt/$tx/$ty'];
        if (img == null) continue;
        final ox = tx * drawnTile - cx + size.width / 2;
        final oy = ty * drawnTile - cy + size.height / 2;
        canvas.drawImageRect(
          img,
          ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          ui.Rect.fromLTWH(ox, oy, drawnTile + 0.5, drawnTile + 0.5),
          ui.Paint(),
        );
      }
    }

    ui.Path? pathOf(String geojson) {
      try {
        final g = jsonDecode(geojson) as Map<String, dynamic>;
        final path = ui.Path();
        void ring(List coords) {
          for (var i = 0; i < coords.length; i++) {
            final c = coords[i] as List;
            final (x, y) = screenOf(
              (c[1] as num).toDouble(),
              (c[0] as num).toDouble(),
              size,
            );
            i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
          }
        }

        switch (g['type']) {
          case 'Polygon':
            for (final r in g['coordinates'] as List) {
              ring(r as List);
              path.close();
            }
          case 'MultiPolygon':
            for (final p in g['coordinates'] as List) {
              for (final r in p as List) {
                ring(r as List);
                path.close();
              }
            }
          case 'LineString':
            ring(g['coordinates'] as List);
          default:
            return null;
        }
        return path;
      } catch (_) {
        return null;
      }
    }

    // Zones — same colour resolution as the plate.
    for (var i = 0; i < subject.zones.length; i++) {
      final z = subject.zones[i];
      final path = pathOf(z.geojson);
      if (path == null) continue;
      final ink = ui.Color(MapPlate.zoneInk(z, i));
      canvas.drawPath(path, ui.Paint()..color = ink.withValues(alpha: 0.22));
      canvas.drawPath(
        path,
        ui.Paint()
          ..color = ink
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    // Boundary.
    if (subject.boundaryGeojson != null) {
      final path = pathOf(subject.boundaryGeojson!);
      if (path != null) {
        canvas.drawPath(
          path,
          ui.Paint()
            ..color = const ui.Color(0xCCFFFFFF)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 5,
        );
        canvas.drawPath(
          path,
          ui.Paint()
            ..color = const ui.Color(0xFF8B2E22)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }
    }

    // Tracks.
    for (final t in subject.tracks) {
      final path = pathOf(t.geojson);
      if (path == null) continue;
      canvas.drawPath(
        path,
        ui.Paint()
          ..color = const ui.Color(0xB3FFFFFF)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = ui.StrokeCap.round,
      );
      canvas.drawPath(
        path,
        ui.Paint()
          ..color = const ui.Color(0xFF1B1813)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = ui.StrokeCap.round,
      );
    }

    // Features — the class silhouettes, white halo (the features layer).
    for (final f in subject.features) {
      try {
        final g = jsonDecode(f.geojson) as Map<String, dynamic>;
        if (g['type'] != 'Point') {
          final path = pathOf(f.geojson);
          if (path == null) continue;
          final ink = ui.Color(switch (f.featureClass) {
            'problem' => 0xFF8B2E22,
            'infrastructure' => 0xFF1B1813,
            _ => 0xFF2F5D8A,
          });
          canvas.drawPath(
            path,
            ui.Paint()
              ..color = ink
              ..style = ui.PaintingStyle.stroke
              ..strokeWidth = 2,
          );
          continue;
        }
        final c = g['coordinates'] as List;
        final (x, y) = screenOf(
          (c[1] as num).toDouble(),
          (c[0] as num).toDouble(),
          size,
        );
        final halo = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
        switch (f.featureClass) {
          case 'problem':
            final tri = ui.Path()
              ..moveTo(x, y - 9)
              ..lineTo(x + 8, y + 6)
              ..lineTo(x - 8, y + 6)
              ..close();
            canvas.drawPath(
              tri,
              halo
                ..style = ui.PaintingStyle.stroke
                ..strokeWidth = 4
                ..strokeJoin = ui.StrokeJoin.round,
            );
            canvas.drawPath(
              tri,
              ui.Paint()..color = const ui.Color(0xFF8B2E22),
            );
          case 'infrastructure':
            final rect = ui.Rect.fromCenter(
              center: ui.Offset(x, y),
              width: 12,
              height: 12,
            );
            canvas.drawRect(rect.inflate(2), halo);
            canvas.drawRect(
              rect,
              ui.Paint()..color = const ui.Color(0xFF1B1813),
            );
          default:
            canvas.drawCircle(ui.Offset(x, y), 8, halo);
            canvas.drawCircle(
              ui.Offset(x, y),
              6,
              ui.Paint()..color = const ui.Color(0xFF2F5D8A),
            );
            canvas.drawCircle(
              ui.Offset(x, y),
              2.5,
              ui.Paint()..color = const ui.Color(0xFFFFFFFF),
            );
        }
      } catch (_) {}
    }

    // Records — the shared shape language, paper stroke. With a species
    // highlighted, everything else dims and the highlighted marks draw
    // last with a gold ring: the map becomes that species' map.
    final dimmed = <PlateRecord>[];
    final lit = <PlateRecord>[];
    for (final r in subject.records) {
      final key = r.label ?? '__type:${r.type}';
      (highlightKey == null || key == highlightKey ? lit : dimmed).add(r);
    }
    for (final r in dimmed) {
      _drawRecord(canvas, size, r, dim: true);
    }
    for (final r in lit) {
      _drawRecord(canvas, size, r, ringed: highlightKey != null);
    }
  }

  void _drawRecord(
    ui.Canvas canvas,
    Size size,
    PlateRecord r, {
    bool dim = false,
    bool ringed = false,
  }) {
    final (x, y) = screenOf(r.lat, r.lng, size);
    if (x < -20 || y < -20 || x > size.width + 20 || y > size.height + 20) {
      return;
    }
    final mark = markFor(r.type);
    final alpha = dim ? 0.30 : 1.0;
    final paper = ui.Paint()
      ..color = const ui.Color(0xFFECE3CE).withValues(alpha: alpha);
    final fill = ui.Paint()
      ..color = ui.Color(mark.argb).withValues(alpha: alpha);
    if (r.id != null && r.id == selectedId) {
      canvas.drawCircle(
        ui.Offset(x, y),
        14,
        ui.Paint()..color = const ui.Color(0x338B2E22),
      );
    }
    if (ringed) {
      canvas.drawCircle(
        ui.Offset(x, y),
        12,
        ui.Paint()
          ..color = const ui.Color(0xFFD9A521)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
    switch (mark.shape) {
      case RecordShape.circle:
        canvas.drawCircle(ui.Offset(x, y), 7.5, paper);
        canvas.drawCircle(ui.Offset(x, y), 6, fill);
      case RecordShape.square:
        final rect = ui.Rect.fromCenter(
          center: ui.Offset(x, y),
          width: 11,
          height: 11,
        );
        canvas.drawRect(rect.inflate(1.8), paper);
        canvas.drawRect(rect, fill);
      case RecordShape.triangle:
        final tri = ui.Path()
          ..moveTo(x, y - 8)
          ..lineTo(x + 7, y + 5)
          ..lineTo(x - 7, y + 5)
          ..close();
        canvas.drawPath(
          tri,
          ui.Paint()
            ..color = const ui.Color(0xFFECE3CE).withValues(alpha: alpha)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 3.5
            ..strokeJoin = ui.StrokeJoin.round,
        );
        canvas.drawPath(tri, fill);
    }
  }

  @override
  bool shouldRepaint(covariant _DeskMapPainter old) => true;
}
