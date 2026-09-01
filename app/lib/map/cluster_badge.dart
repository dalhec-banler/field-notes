import 'dart:typed_data';
import 'dart:ui' as ui;

/// A cluster badge as a PNG for the map's symbol layer: ink dot, paper ring,
/// the count. Drawn once per distinct count and cached by the map screen.
/// Icon images sidestep the glyph question — an offline style may have no
/// font ranges, but it can always draw a picture.
Future<Uint8List> clusterBadge(int count, {double scale = 3}) async {
  final label = count > 99 ? '99+' : '$count';
  final radius = count >= 50
      ? 18.0
      : count >= 10
      ? 15.0
      : 12.5;
  final size = (radius + 2.5) * 2;
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.scale(scale);
  final centre = ui.Offset(size / 2, size / 2);
  c.drawCircle(
    centre,
    radius + 2.5,
    ui.Paint()..color = const ui.Color(0xFFECE3CE),
  );
  c.drawCircle(centre, radius, ui.Paint()..color = const ui.Color(0xFF1B1813));
  final pb =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            textAlign: ui.TextAlign.center,
            fontSize: count > 99 ? 10 : 12,
          ),
        )
        ..pushStyle(
          ui.TextStyle(
            color: const ui.Color(0xFFF7F6F2),
            fontSize: count > 99 ? 10 : 12,
            fontWeight: ui.FontWeight.w700,
            fontFamily: 'JetBrainsMono',
            fontFamilyFallback: const ['Roboto', 'sans-serif'],
          ),
        )
        ..addText(label);
  final p = pb.build()..layout(ui.ParagraphConstraints(width: size));
  c.drawParagraph(p, ui.Offset(0, size / 2 - p.height / 2));
  final img = await rec.endRecording().toImage(
    (size * scale).round(),
    (size * scale).round(),
  );
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bytes!.buffer.asUint8List();
}
