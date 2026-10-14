import 'dart:ui' as ui;

import 'record_ink.dart';

/// The survey-station glyph a monitoring protocol site wears (D-033): a
/// paper square outlined in ink, a crosshair whose four arms cross the
/// square's sides, and a dot at the stake. One painter, three surfaces —
/// the phone draws it into a bitmap at 3×, the desk and the plate draw it
/// straight onto their canvases — so a site looks the same everywhere.
///
/// [r] is half the square's width; the arms reach 1.5·r, so the whole
/// mark spans 3·r. Pass the size a surface gives its photo-point bug and
/// the two read as siblings: stations of different kinds.
void paintProtocolSite(
  ui.Canvas c,
  ui.Offset centre, {
  required double r,
  bool retired = false,
}) {
  final alpha = retired ? protocolSiteRetiredAlpha : 1.0;
  final ink = ui.Color(protocolSiteInk).withValues(alpha: alpha);
  final paper = ui.Color(protocolSitePaper).withValues(alpha: alpha);
  final stroke = (r * 0.18).clamp(1.2, 4.0);
  final square = ui.Rect.fromCenter(
    center: centre,
    width: 2 * r,
    height: 2 * r,
  );

  // The four arms: from just inside the square out past its edge, leaving
  // the middle clear for the stake.
  final arms = ui.Path();
  for (final (dx, dy) in const [
    (1.0, 0.0),
    (-1.0, 0.0),
    (0.0, 1.0),
    (0.0, -1.0),
  ]) {
    arms
      ..moveTo(centre.dx + dx * r * 0.55, centre.dy + dy * r * 0.55)
      ..lineTo(centre.dx + dx * r * 1.5, centre.dy + dy * r * 1.5);
  }

  // Paper under everything so the ink holds on imagery: a filled square
  // and a wide stroke along the arms.
  c.drawRect(square.inflate(stroke), ui.Paint()..color = paper);
  c.drawPath(
    arms,
    ui.Paint()
      ..color = paper
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = stroke * 3
      ..strokeCap = ui.StrokeCap.round,
  );

  final inkStroke = ui.Paint()
    ..color = ink
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = stroke
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.miter;
  c.drawRect(square, inkStroke);
  c.drawPath(arms, inkStroke);
  c.drawCircle(centre, r * 0.28, ui.Paint()..color = ink);
}
