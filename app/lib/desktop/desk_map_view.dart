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

/// The desk's map (Austin, 2026-09-03: "there is no way to interface with
/// the map in the same way you do on the phone — critically important").
///
/// maplibre_gl has no desktop platform, so this is our own slippy map on
/// the machinery the plate already proved: web-mercator math, XYZ imagery
/// tiles, and the shared record mark language. Drag to pan, scroll or
/// double-click to zoom, click a mark to open the record beside the map —
/// where ADD PHOTOS takes files from a real camera's card (D-024: the desk
/// refines; the phone originates).
class DeskMapWorkspace extends StatefulWidget {
  DeskMapWorkspace({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<DeskMapWorkspace> createState() => _DeskMapWorkspaceState();
}

class _DeskMapWorkspaceState extends State<DeskMapWorkspace> {
  PlateSubject? _subject;
  String? _selectedId;
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

  TileFetcher _buildFetcher() {
    final primary = httpTileFetcher(template: activeImagery.template);
    final chained = activeImagery.id == 'usgs'
        ? primary
        : tileFetcherWithFallback(primary, httpTileFetcher());
    return _tiles.wrap(chained);
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
    if (frame || _lat == null) _frameSubject(s);
  }

  void _frameSubject(PlateSubject s) {
    final b = MapPlate.frameBounds(s, const PlateLayers(records: true));
    setState(() {
      _lat = (b.north + b.south) / 2;
      _lng = (b.east + b.west) / 2;
      _zoom = merc
          .zoomFor(b, 900, 700, maxZoom: activeImagery.maxZoom)
          .toDouble();
    });
  }

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

  void _panBy(Offset delta, Size size) {
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
    // Keep the point under the cursor still: pan so `about` maps to the
    // same coordinate after the zoom.
    final beforeCentre = Offset(size.width / 2, size.height / 2);
    final (aLatLng) = _latLngAt(about, size);
    setState(() {
      _zoom = (_zoom + dz).clamp(4.0, activeImagery.maxZoom + 0.99);
    });
    final (ax, ay) = _screenOf(aLatLng.$1, aLatLng.$2, size);
    _panBy(Offset(beforeCentre.dx - ax, beforeCentre.dy - ay) * -1, size);
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
    final left = ((cx - size.width / 2) / (merc.tileSize * _tileScale)).floor();
    final top = ((cy - size.height / 2) / (merc.tileSize * _tileScale)).floor();
    final right = ((cx + size.width / 2) / (merc.tileSize * _tileScale))
        .floor();
    final bottom = ((cy + size.height / 2) / (merc.tileSize * _tileScale))
        .floor();
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
        _fetch(z, tx, ty).then((bytes) async {
          _inflight.remove(key);
          if (bytes == null) {
            _missing.add(key);
            return;
          }
          try {
            final codec = await ui.instantiateImageCodec(bytes);
            final img = (await codec.getNextFrame()).image;
            codec.dispose();
            if (!mounted) {
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
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
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
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Container(
          width: 380,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: Press.borderInk, width: 1.5),
            ),
          ),
          child: _selectedId == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Click a mark to open its record here. ADD PHOTOS '
                      'takes files straight from this computer — the way '
                      'in for a better camera\'s shots.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 14.5,
                        height: 1.5,
                        color: Press.inkSoft,
                      ),
                    ),
                  ),
                )
              : RecordDetailScreen(
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

class _DeskMapPainter extends CustomPainter {
  _DeskMapPainter({
    required this.subject,
    required this.images,
    required this.zInt,
    required this.tileScale,
    required this.centre,
    required this.selectedId,
    required this.screenOf,
  });

  final PlateSubject subject;
  final Map<String, ui.Image> images;
  final int zInt;
  final double tileScale;
  final (double, double) centre;
  final String? selectedId;
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

    // Records — the shared shape language, paper stroke (the record layer).
    final paper = ui.Paint()..color = const ui.Color(0xFFECE3CE);
    for (final r in subject.records) {
      final (x, y) = screenOf(r.lat, r.lng, size);
      if (x < -20 || y < -20 || x > size.width + 20 || y > size.height + 20) {
        continue;
      }
      final mark = markFor(r.type);
      final fill = ui.Paint()..color = ui.Color(mark.argb);
      final selected = r.id != null && r.id == selectedId;
      if (selected) {
        canvas.drawCircle(
          ui.Offset(x, y),
          14,
          ui.Paint()..color = const ui.Color(0x338B2E22),
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
              ..color = const ui.Color(0xFFECE3CE)
              ..style = ui.PaintingStyle.stroke
              ..strokeWidth = 3.5
              ..strokeJoin = ui.StrokeJoin.round,
          );
          canvas.drawPath(tri, fill);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DeskMapPainter old) => true;
}
