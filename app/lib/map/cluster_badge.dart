import 'dart:typed_data';
import 'dart:ui' as ui;

import 'record_clusters.dart' show clusterLabel;

/// Badge radius for a count — the smallest badge must out-size the
/// largest dot (Austin, 2026-09-03: badges drew smaller than the dots
/// they gather). Unit scale is the phone's: DEVICE pixels at 1/3 icon
/// scale, since addImage registers at density 1.
double clusterBadgeRadius(int count) => count >= 50
    ? 34.0
    : count >= 10
    ? 30.0
    : 27.0;

/// A cluster badge on [canvas] at [centre]: ink dot, paper ring, the
/// count. One drawing for both maps — the phone rasterises it once per
/// count for its symbol layer ([clusterBadge]); the desk painter scales
/// the canvas and draws it live on every frame, with [alpha] under 1 for
/// a dimmed badge.
void paintClusterBadge(
  ui.Canvas canvas,
  ui.Offset centre,
  int count, {
  double alpha = 1,
}) {
  final label = clusterLabel(count);
  final radius = clusterBadgeRadius(count);
  canvas.drawCircle(
    centre,
    radius + 2.5,
    ui.Paint()..color = const ui.Color(0xFFECE3CE).withValues(alpha: alpha),
  );
  canvas.drawCircle(
    centre,
    radius,
    ui.Paint()..color = const ui.Color(0xFF1B1813).withValues(alpha: alpha),
  );
  final p = _paragraphs['$label@$alpha'] ??= _shape(label, radius, alpha);
  canvas.drawParagraph(
    p,
    ui.Offset(centre.dx - radius, centre.dy - p.height / 2),
  );
}

/// Laid-out counts, by label and alpha: '1'..'99', '99+' — shaping text
/// per badge per frame was the desk map's whole drag cost.
final _paragraphs = <String, ui.Paragraph>{};

ui.Paragraph _shape(String label, double radius, double alpha) {
  final fontSize = label.endsWith('+') ? 20.0 : 24.0;
  final pb =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(textAlign: ui.TextAlign.center, fontSize: fontSize),
        )
        ..pushStyle(
          ui.TextStyle(
            color: const ui.Color(0xFFF7F6F2).withValues(alpha: alpha),
            fontSize: fontSize,
            fontWeight: ui.FontWeight.w700,
            fontFamily: 'JetBrainsMono',
            fontFamilyFallback: const ['Roboto', 'sans-serif'],
          ),
        )
        ..addText(label);
  return pb.build()..layout(ui.ParagraphConstraints(width: radius * 2));
}

/// A cluster badge as a PNG for the map's symbol layer. Drawn once per
/// distinct count and cached by the map screen. Icon images sidestep the
/// glyph question — an offline style may have no font ranges, but it can
/// always draw a picture.
Future<Uint8List> clusterBadge(int count, {double scale = 3}) async {
  final size = (clusterBadgeRadius(count) + 2.5) * 2;
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.scale(scale);
  paintClusterBadge(c, ui.Offset(size / 2, size / 2), count);
  final img = await rec.endRecording().toImage(
    (size * scale).round(),
    (size * scale).round(),
  );
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bytes!.buffer.asUint8List();
}
