part of '../map_plate.dart';

// ── drawing helpers ────────────────────────────────────────────────

void _drawMissingTile(ui.Canvas c, double ox, double oy) {
  c.drawRect(
    ui.Rect.fromLTWH(ox, oy, tileSize, tileSize),
    ui.Paint()..color = const ui.Color(0xFFE8E6DF),
  );
  final p = ui.Paint()
    ..color = const ui.Color(0x22000000)
    ..strokeWidth = 1;
  for (var d = -tileSize; d < tileSize; d += 24) {
    c.drawLine(
      ui.Offset(ox + d, oy + tileSize),
      ui.Offset(ox + d + tileSize, oy),
      p,
    );
  }
}

/// The shared shape language (record_ink): circle for the grown and
/// observed, square for the built, triangle for trouble — white halo,
/// as everything prints.
void _drawRecordMark(
  ui.Canvas c,
  double x,
  double y,
  String type, {
  int? colorOverride,
}) {
  final mark = markFor(type);
  final ink = colorOverride ?? mark.argb;
  switch (mark.shape) {
    case RecordShape.circle:
      _drawRecordDot(c, x, y, ink);
    case RecordShape.square:
      final rect = ui.Rect.fromCenter(
        center: ui.Offset(x, y),
        width: 10,
        height: 10,
      );
      c.drawRect(
        rect.inflate(2),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF),
      );
      c.drawRect(rect, ui.Paint()..color = ui.Color(ink));
    case RecordShape.triangle:
      final tri = ui.Path()
        ..moveTo(x, y - 7)
        ..lineTo(x + 6, y + 4.5)
        ..lineTo(x - 6, y + 4.5)
        ..close();
      c.drawPath(
        tri,
        ui.Paint()
          ..color = const ui.Color(0xFFFFFFFF)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = ui.StrokeJoin.round,
      );
      c.drawPath(tri, ui.Paint()..color = ui.Color(ink));
  }
}

/// D-027 around any mark: a red ring while it's flagged, an ink ring
/// with a tick once it's out. The mark inside still shows.
void _drawRemovalRing(
  ui.Canvas c,
  double x,
  double y, {
  required bool flagged,
}) {
  final ink = ui.Color(flagged ? removalRed : PlateInk.ink);
  c.drawCircle(
    ui.Offset(x, y),
    10,
    ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 3.5,
  );
  final stroke = ui.Paint()
    ..color = ink
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.8
    ..strokeCap = ui.StrokeCap.round;
  c.drawCircle(ui.Offset(x, y), 10, stroke);
  if (!flagged) {
    final tick = ui.Path()
      ..moveTo(x - 4.5, y + 0.5)
      ..lineTo(x - 1.5, y + 3.5)
      ..lineTo(x + 5, y - 3.5);
    c.drawPath(tick, stroke);
  }
}

/// A numbered oxblood pin for the removal plan.
void _drawNumberBadge(ui.Canvas c, double x, double y, String label) {
  final r = label.length >= 4
      ? 15.0
      : label.length == 3
      ? 13.0
      : 11.0;
  c.drawCircle(
    ui.Offset(x, y),
    r + 1.5,
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  c.drawCircle(
    ui.Offset(x, y),
    r,
    ui.Paint()..color = ui.Color(PlateInk.oxblood),
  );
  final pb =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(textAlign: ui.TextAlign.center, fontSize: 10),
        )
        ..pushStyle(
          ui.TextStyle(
            color: const ui.Color(0xFFF7F6F2),
            fontSize: label.length >= 3 ? 8.5 : 10,
            fontWeight: ui.FontWeight.w700,
            fontFamily: 'JetBrainsMono',
            fontFamilyFallback: const ['Roboto', 'sans-serif'],
          ),
        )
        ..addText(label);
  final p = pb.build()..layout(ui.ParagraphConstraints(width: r * 2));
  c.drawParagraph(p, ui.Offset(x - r, y - p.height / 2));
}

void _drawRecordDot(ui.Canvas c, double x, double y, int color) {
  c.drawCircle(
    ui.Offset(x, y),
    6.5,
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  c.drawCircle(ui.Offset(x, y), 5, ui.Paint()..color = ui.Color(color));
}

void _drawCountBadge(ui.Canvas c, double x, double y, int n) {
  final r = n >= 50
      ? 16.0
      : n >= 10
      ? 13.0
      : 11.0;
  c.drawCircle(
    ui.Offset(x, y),
    r + 1.5,
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  c.drawCircle(
    ui.Offset(x, y),
    r,
    ui.Paint()..color = ui.Color(PlateInk.ink),
  );
  _drawLabel(
    c,
    '$n',
    x,
    y,
    size: n >= 100 ? 10 : 12,
    color: PlateInk.paper,
    center: true,
    middle: true,
  );
}

void _drawFeatureMarker(
  ui.Canvas c,
  double x,
  double y,
  String cls,
  int color,
) {
  final halo = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
  final fill = ui.Paint()..color = ui.Color(color);
  switch (cls) {
    case 'problem':
      final tri = ui.Path()
        ..moveTo(x, y - 9)
        ..lineTo(x + 8, y + 6)
        ..lineTo(x - 8, y + 6)
        ..close();
      c.drawPath(
        tri,
        halo
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 4,
      );
      c.drawPath(tri, fill);
    case 'infrastructure':
      final rect = ui.Rect.fromCenter(
        center: ui.Offset(x, y),
        width: 13,
        height: 13,
      );
      c.drawRect(rect.inflate(1.5), halo..style = ui.PaintingStyle.fill);
      c.drawRect(rect, fill);
    default:
      c.drawCircle(ui.Offset(x, y), 8, halo..style = ui.PaintingStyle.fill);
      c.drawCircle(ui.Offset(x, y), 6.5, fill);
      c.drawCircle(
        ui.Offset(x, y),
        2.5,
        ui.Paint()..color = const ui.Color(0xFFFFFFFF),
      );
  }
}

ui.Paragraph _paragraph(
  String text,
  double size, {
  int color = PlateInk.ink,
  bool bold = false,
  ui.TextAlign align = ui.TextAlign.left,
  double maxWidth = 2000,
}) {
  final b =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(textAlign: align, fontSize: size, maxLines: 2),
        )
        ..pushStyle(
          ui.TextStyle(
            color: ui.Color(color),
            fontSize: size,
            fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w500,
            fontFamily: 'JetBrainsMono',
            fontFamilyFallback: const ['Menlo', 'monospace'],
          ),
        )
        ..addText(text);
  return b.build()..layout(ui.ParagraphConstraints(width: maxWidth));
}

void _drawLabel(
  ui.Canvas c,
  String text,
  double x,
  double y, {
  double size = 12,
  int color = PlateInk.ink,
  bool halo = false,
  bool center = false,
  bool middle = false,
  bool bold = false,
}) {
  final p = _paragraph(text, size, color: color, bold: bold);
  final w = p.longestLine;
  final h = p.height;
  final dx = center ? x - w / 2 : x;
  final dy = middle ? y - h / 2 : y;
  if (halo) {
    c.drawRRect(
      ui.RRect.fromRectAndRadius(
        ui.Rect.fromLTWH(dx - 5, dy - 2, w + 10, h + 4),
        const ui.Radius.circular(3),
      ),
      ui.Paint()..color = const ui.Color(0xD9F7F6F2),
    );
  }
  c.drawParagraph(p, ui.Offset(dx, dy));
}

