import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'record_ink.dart';

/// Marker images for the phone map, drawn once at 3× and added to the
/// style with addImage. Images rather than circle layers because the map
/// needs *shapes*: your position is a view-finder, not another dot the
/// colour of a tree; features read apart from records by silhouette.

const positionBlue = 0xFF1D6FE0;

/// Your position: a view-finder reticle — ring, four ticks, centre dot —
/// in a signal blue nothing else on the map uses.
Future<Uint8List> positionReticle({double scale = 3}) async {
  const size = 48.0;
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec)..scale(scale);
  final centre = const ui.Offset(size / 2, size / 2);
  const r = 14.0;
  final blue = ui.Paint()
    ..color = const ui.Color(positionBlue)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2.5
    ..strokeCap = ui.StrokeCap.round;
  final halo = ui.Paint()
    ..color = const ui.Color(0xFFFFFFFF)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 5.5
    ..strokeCap = ui.StrokeCap.round;
  // Soft fill so it still reads over busy imagery.
  c.drawCircle(centre, r, ui.Paint()..color = const ui.Color(0x221D6FE0));
  // Ticks at N/E/S/W, outside the ring.
  for (var i = 0; i < 4; i++) {
    final a = i * math.pi / 2;
    final from = centre + ui.Offset(math.cos(a), math.sin(a)) * (r + 2);
    final to = centre + ui.Offset(math.cos(a), math.sin(a)) * (r + 8);
    c.drawLine(from, to, halo);
  }
  c.drawCircle(centre, r, halo);
  for (var i = 0; i < 4; i++) {
    final a = i * math.pi / 2;
    final from = centre + ui.Offset(math.cos(a), math.sin(a)) * (r + 2);
    final to = centre + ui.Offset(math.cos(a), math.sin(a)) * (r + 8);
    c.drawLine(from, to, blue);
  }
  c.drawCircle(centre, r, blue);
  c.drawCircle(centre, 4.5, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  c.drawCircle(centre, 3, ui.Paint()..color = const ui.Color(positionBlue));
  return _png(rec, size, scale);
}

/// Feature markers by class, same silhouettes as the printed plate:
/// natural = blue ring with a white eye, infrastructure = ink square,
/// problem = oxblood triangle. All on a white halo.
Future<Uint8List> featureMarker(String featureClass, {double scale = 3}) async {
  const size = 30.0;
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec)..scale(scale);
  const centre = ui.Offset(size / 2, size / 2);
  final halo = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
  switch (featureClass) {
    case 'problem':
      final fill = ui.Paint()..color = const ui.Color(0xFF8B2E22);
      final tri = ui.Path()
        ..moveTo(centre.dx, centre.dy - 10)
        ..lineTo(centre.dx + 9, centre.dy + 7)
        ..lineTo(centre.dx - 9, centre.dy + 7)
        ..close();
      c.drawPath(
        tri,
        halo
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeJoin = ui.StrokeJoin.round,
      );
      c.drawPath(tri, fill);
    case 'infrastructure':
      final fill = ui.Paint()..color = const ui.Color(0xFF1B1813);
      final rect = ui.Rect.fromCenter(center: centre, width: 14, height: 14);
      c.drawRect(rect.inflate(2.5), halo);
      c.drawRect(rect, fill);
    default:
      final fill = ui.Paint()..color = const ui.Color(0xFF2F5D8A);
      c.drawCircle(centre, 10, halo);
      c.drawCircle(centre, 7.5, fill);
      c.drawCircle(centre, 3, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  }
  return _png(rec, size, scale);
}

/// Record marks that aren't circles (Austin, 2026-09-03): shape says what
/// kind of thing the record is. Built things are squares (infrastructure =
/// ink, maintenance = ochre), trouble is an oxblood triangle; everything
/// else stays a circle. They wear the record layer's PAPER stroke — not
/// the features' white halo — so shape carries class while the halo still
/// says which layer a mark belongs to. Sized in device pixels to carry the
/// same visual weight as the 9.5-logical-px record dots.
Future<Uint8List> recordShapeMarker(String kind, {double scale = 3}) async {
  const size = 56.0;
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec)..scale(scale);
  const centre = ui.Offset(size / 2, size / 2);
  final paper = ui.Paint()..color = const ui.Color(0xFFECE3CE);
  switch (kind) {
    case 'problem':
      final tri = ui.Path()
        ..moveTo(centre.dx, centre.dy - 22)
        ..lineTo(centre.dx + 19, centre.dy + 14)
        ..lineTo(centre.dx - 19, centre.dy + 14)
        ..close();
      c.drawPath(
        tri,
        paper
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 8
          ..strokeJoin = ui.StrokeJoin.round,
      );
      c.drawPath(tri, ui.Paint()..color = ui.Color(markFor(kind).argb));
    default: // infrastructure, maintenance — the squares
      final rect = ui.Rect.fromCenter(center: centre, width: 40, height: 40);
      c.drawRect(rect.inflate(4), paper);
      c.drawRect(rect, ui.Paint()..color = ui.Color(markFor(kind).argb));
  }
  return _png(rec, size, scale);
}

Future<Uint8List> _png(
  ui.PictureRecorder rec,
  double size,
  double scale,
) async {
  final img = await rec.endRecording().toImage(
    (size * scale).round(),
    (size * scale).round(),
  );
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bytes!.buffer.asUint8List();
}
