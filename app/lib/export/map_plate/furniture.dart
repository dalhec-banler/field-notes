part of '../map_plate.dart';

void _drawMapFurniture(
  ui.Canvas c,
  PlateFrame frame, {
  required String attribution,
  required int missing,
}) {
  final w = frame.width.toDouble();
  final h = frame.height.toDouble();

  // Scale bar + north, bottom-left.
  final midLat = (frame.bounds.north + frame.bounds.south) / 2;
  final (metres, px) = scaleBar(midLat, frame.zoom);
  final label = metres >= 1000
      ? '${(metres / 1000).toStringAsFixed(metres % 1000 == 0 ? 0 : 1)} km'
      : '${metres.toStringAsFixed(0)} m';
  const sbx = 12.0;
  final sby = h - 12 - 34;
  c.drawRect(
    ui.Rect.fromLTWH(sbx, sby, px + 56, 34),
    ui.Paint()..color = const ui.Color(0xF2F7F6F2),
  );
  c.drawRect(
    ui.Rect.fromLTWH(sbx + 8, sby + 22, px, 4),
    ui.Paint()..color = ui.Color(PlateInk.ink),
  );
  c.drawRect(
    ui.Rect.fromLTWH(sbx + 8, sby + 22, px / 2, 4),
    ui.Paint()..color = ui.Color(PlateInk.paper),
  );
  c.drawRect(
    ui.Rect.fromLTWH(sbx + 8, sby + 22, px, 4),
    ui.Paint()
      ..color = ui.Color(PlateInk.ink)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1,
  );
  _drawLabel(c, label, sbx + 8, sby + 4, size: 10);
  final nx = sbx + px + 34;
  final arrow = ui.Path()
    ..moveTo(nx, sby + 6)
    ..lineTo(nx + 6, sby + 26)
    ..lineTo(nx, sby + 21)
    ..lineTo(nx - 6, sby + 26)
    ..close();
  c.drawPath(arrow, ui.Paint()..color = ui.Color(PlateInk.ink));
  _drawLabel(c, 'N', nx, sby - 8, size: 9, center: true, bold: true);

  // Attribution (+ missing tiles), bottom-right.
  final att = missing > 0
      ? '$attribution · $missing tile${missing == 1 ? '' : 's'} unavailable'
      : attribution;
  final ap = _paragraph(att, 9, color: 0xFF6B655C);
  c.drawRect(
    ui.Rect.fromLTWH(
      w - ap.longestLine - 24,
      h - ap.height - 18,
      ap.longestLine + 12,
      ap.height + 6,
    ),
    ui.Paint()..color = const ui.Color(0xD9F7F6F2),
  );
  c.drawParagraph(ap, ui.Offset(w - ap.longestLine - 18, h - ap.height - 15));
}

