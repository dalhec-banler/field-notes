import 'dart:math' as math;

/// Douglas-Peucker simplification for track polylines (spec §4.13, ~5 m
/// tolerance). Points are (lng, lat) GeoJSON order.
List<List<double>> simplifyTrack(
  List<List<double>> points, {
  double toleranceM = 5,
}) {
  if (points.length <= 2) return points;
  final keep = List<bool>.filled(points.length, false);
  keep[0] = true;
  keep[points.length - 1] = true;
  _dp(points, 0, points.length - 1, toleranceM, keep);
  return [
    for (var i = 0; i < points.length; i++)
      if (keep[i]) points[i],
  ];
}

void _dp(
  List<List<double>> pts,
  int start,
  int end,
  double tolM,
  List<bool> keep,
) {
  if (end <= start + 1) return;
  var maxDist = 0.0;
  var maxIdx = start;
  for (var i = start + 1; i < end; i++) {
    final d = _perpDistM(pts[i], pts[start], pts[end]);
    if (d > maxDist) {
      maxDist = d;
      maxIdx = i;
    }
  }
  if (maxDist > tolM) {
    keep[maxIdx] = true;
    _dp(pts, start, maxIdx, tolM, keep);
    _dp(pts, maxIdx, end, tolM, keep);
  }
}

/// Perpendicular distance in meters using a local equirectangular projection —
/// fine at track scale.
double _perpDistM(List<double> p, List<double> a, List<double> b) {
  final latRad = p[1] * math.pi / 180;
  final mPerDegLat = 111320.0;
  final mPerDegLng = 111320.0 * math.cos(latRad);
  final px = (p[0] - a[0]) * mPerDegLng;
  final py = (p[1] - a[1]) * mPerDegLat;
  final bx = (b[0] - a[0]) * mPerDegLng;
  final by = (b[1] - a[1]) * mPerDegLat;
  final lenSq = bx * bx + by * by;
  if (lenSq == 0) return math.sqrt(px * px + py * py);
  final t = ((px * bx + py * by) / lenSq).clamp(0.0, 1.0);
  final dx = px - t * bx;
  final dy = py - t * by;
  return math.sqrt(dx * dx + dy * dy);
}

/// Haversine distance in meters between (lng, lat) positions.
double distanceM(List<double> a, List<double> b) {
  const r = 6371000.0;
  final dLat = (b[1] - a[1]) * math.pi / 180;
  final dLng = (b[0] - a[0]) * math.pi / 180;
  final la1 = a[1] * math.pi / 180;
  final la2 = b[1] * math.pi / 180;
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.asin(math.sqrt(h));
}

/// Total path length in meters.
double pathLengthM(List<List<double>> points) {
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += distanceM(points[i - 1], points[i]);
  }
  return total;
}

/// Initial bearing in degrees from a to b ((lng, lat) positions).
double bearingDeg(List<double> a, List<double> b) {
  final la1 = a[1] * math.pi / 180;
  final la2 = b[1] * math.pi / 180;
  final dLng = (b[0] - a[0]) * math.pi / 180;
  final y = math.sin(dLng) * math.cos(la2);
  final x =
      math.cos(la1) * math.sin(la2) -
      math.sin(la1) * math.cos(la2) * math.cos(dLng);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}
