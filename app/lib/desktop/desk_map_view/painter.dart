part of '../desk_map_view.dart';

/// The ring the map draws around a record that is coming out (D-027),
/// at list size: red while flagged, ink once removed, nothing otherwise.
/// Too small for the tick; the colour carries the difference.
class _RemovalRing extends StatelessWidget {
  const _RemovalRing({required this.removal, required this.child});
  final String? removal;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (removal == null) return child;
    final ink = removal == 'flagged' ? Color(removalRed) : Press.ink;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ink, width: 1.5),
      ),
      child: child,
    );
  }
}

/// The mark swatch beside a species row — same shape language as the map.
class _MarkSwatch extends StatelessWidget {
  const _MarkSwatch({required this.type, this.removal});
  final String type;
  final String? removal;

  @override
  Widget build(BuildContext context) {
    final mark = markFor(type);
    final color = Color(mark.argb);
    return _RemovalRing(removal: removal, child: _shape(mark, color));
  }

  Widget _shape(RecordMark mark, Color color) {
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

/// Paints the layer set to the desk's canvas: imagery tiles, then each
/// layer in the set's draw order. The clustering is done by the state
/// (it depends on zoom, highlight and selection), so the records layer
/// arrives here already cut into [lit] and [dimmed] cells.
class _DeskMapPainter extends CustomPainter {
  _DeskMapPainter({
    required this.layers,
    required this.lit,
    required this.dimmed,
    required this.images,
    required this.zInt,
    required this.tileScale,
    required this.centre,
    required this.selectedId,
    required this.selectedSiteId,
    required this.highlightKey,
    required this.screenOf,
  });

  final MapLayerSet layers;

  /// Records already grouped by the state for this zoom: a one-record
  /// cell draws its mark, a fuller cell draws a badge.
  final List<List<MapRecord>> lit;
  final List<List<MapRecord>> dimmed;
  final Map<String, ui.Image> images;
  final int zInt;
  final double tileScale;
  final (double, double) centre;
  final String? selectedId;
  final String? selectedSiteId;
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
      } catch (e, st) {
        Diag.report(e, st, where: 'DeskMapPainter.paint');
        return null;
      }
    }

    // The place's layers, in the set's draw order. Each case is only how
    // that layer paints here; which layers exist is the model's business.
    for (final layer in layers.layers) {
      switch (layer) {
        case ImageryBase():
          // The tiles above came through the state's fetcher.
          break;

        // Zones — same colour resolution as the plate.
        case ZoneFills(:final zones):
          for (var i = 0; i < zones.length; i++) {
            final path = pathOf(zones[i].geojson);
            if (path == null) continue;
            final ink = ui.Color(layer.inkAt(i));
            canvas.drawPath(
              path,
              ui.Paint()..color = ink.withValues(alpha: 0.22),
            );
            canvas.drawPath(
              path,
              ui.Paint()
                ..color = ink
                ..style = ui.PaintingStyle.stroke
                ..strokeWidth = 1.5,
            );
          }

        case BoundaryLine(:final geojson):
          final path = pathOf(geojson);
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

        case TrackLines(:final tracks):
          for (final t in tracks) {
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
        case FeatureMarks(:final features):
          for (final f in features) {
            try {
              final g = jsonDecode(f.geojson) as Map<String, dynamic>;
              if (g['type'] != 'Point') {
                final path = pathOf(f.geojson);
                if (path == null) continue;
                canvas.drawPath(
                  path,
                  ui.Paint()
                    ..color = ui.Color(f.ink)
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
              _drawFeature(canvas, x, y, f.featureClass);
            } catch (e, st) {
              Diag.report(e, st, where: 'DeskMapPainter.paint');
            }
          }

        case PhotoPointStations():
          // The desk map does not draw stations.
          break;

        // Monitoring sites (D-033) — the shared station glyph, at the
        // size the features draw; the clicked one sits in a soft ring.
        case ProtocolSiteMarks(:final sites):
          for (final s in sites) {
            final (x, y) = screenOf(s.lat, s.lng, size);
            if (x < -20 ||
                y < -20 ||
                x > size.width + 20 ||
                y > size.height + 20) {
              continue;
            }
            if (s.id == selectedSiteId) {
              canvas.drawCircle(
                ui.Offset(x, y),
                16,
                ui.Paint()..color = const ui.Color(0x338B2E22),
              );
            }
            paintProtocolSite(
              canvas,
              ui.Offset(x, y),
              r: 7,
              retired: s.retiredOn != null,
            );
          }

        // Records — the shared shape language, paper stroke; a cell with
        // more than one wears the phone's badge. With a species
        // highlighted, everything else dims and the highlighted marks draw
        // last with a gold ring: the map becomes that species' map.
        case RecordMarks():
          for (final cell in dimmed) {
            if (cell.length > 1) {
              _drawCluster(canvas, size, cell, dim: true);
            } else {
              _drawRecord(canvas, size, cell.single, dim: true);
            }
          }
          for (final cell in lit) {
            if (cell.length > 1) {
              _drawCluster(canvas, size, cell);
            } else {
              _drawRecord(
                canvas,
                size,
                cell.single,
                ringed: highlightKey != null,
              );
            }
          }

        case RecordClusters():
          // Cut by the state into lit / dimmed cells above.
          break;
        case PositionMark():
          // The desk has no fix of its own.
          break;
      }
    }
  }

  /// A feature's point silhouette by class: oxblood triangle for trouble,
  /// ink square for the built, river dot with a white eye for the natural.
  void _drawFeature(ui.Canvas canvas, double x, double y, String cls) {
    final halo = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
    switch (cls) {
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
        canvas.drawPath(tri, ui.Paint()..color = const ui.Color(0xFF8B2E22));
      case 'infrastructure':
        final rect = ui.Rect.fromCenter(
          center: ui.Offset(x, y),
          width: 12,
          height: 12,
        );
        canvas.drawRect(rect.inflate(2), halo);
        canvas.drawRect(rect, ui.Paint()..color = const ui.Color(0xFF1B1813));
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
  }

  /// The phone's badge at desk scale: cluster_badge.dart draws it in the
  /// phone's device pixels; 0.4 lands it just over the desk's dots.
  static const clusterScale = 0.4;

  void _drawCluster(
    ui.Canvas canvas,
    Size size,
    List<MapRecord> cell, {
    bool dim = false,
  }) {
    final (lat, lng) = centreOf(cell, recordCoords);
    final (x, y) = screenOf(lat, lng, size);
    if (x < -30 || y < -30 || x > size.width + 30 || y > size.height + 30) {
      return;
    }
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(clusterScale);
    paintClusterBadge(
      canvas,
      ui.Offset.zero,
      cell.length,
      alpha: dim ? 0.30 : 1.0,
    );
    canvas.restore();
  }

  void _drawRecord(
    ui.Canvas canvas,
    Size size,
    MapRecord r, {
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
    if (r.removal != null) {
      // D-027 around the mark: a red ring while flagged, an ink ring with
      // a tick once it's out — same glyph as the phone and the plate.
      final flagged = r.removal == 'flagged';
      final ringInk =
          (flagged ? ui.Color(removalRed) : const ui.Color(0xFF1B1813))
              .withValues(alpha: alpha);
      canvas.drawCircle(
        ui.Offset(x, y),
        11.5,
        ui.Paint()
          ..color = const ui.Color(0xFFECE3CE).withValues(alpha: alpha)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 4,
      );
      final stroke = ui.Paint()
        ..color = ringInk
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = ui.StrokeCap.round;
      canvas.drawCircle(ui.Offset(x, y), 11.5, stroke);
      if (!flagged) {
        canvas.drawPath(
          ui.Path()
            ..moveTo(x - 5, y + 0.5)
            ..lineTo(x - 1.5, y + 4)
            ..lineTo(x + 5.5, y - 4),
          stroke,
        );
      }
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
