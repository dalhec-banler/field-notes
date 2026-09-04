/// The ground a fixed photo point actually looks at (Austin, 2026-09-04:
/// "fixed photo points taken from the same location, height, direction,
/// and focal length").
///
/// A monitoring station is not a dot — it is a spot AND a direction AND a
/// field of view. Drawn as a wedge on the map, a photo point says "this
/// stand of Tifton, from here, at this focal length", which is what makes
/// the series credible years later.
///
/// Pure math, no Flutter: the phone map, the desk map and the export plate
/// all draw the same wedge.
library;

import 'dart:math' as math;

/// Horizontal field of view (degrees) for a 35 mm-equivalent focal length.
/// 26 mm — a phone's main camera — is about 70°.
double fovDegFor(double? focalLengthMm) {
  final f = (focalLengthMm ?? 26).clamp(8.0, 400.0);
  const sensorWidthMm = 36.0; // 35 mm equivalent
  return 2 * math.atan(sensorWidthMm / (2 * f)) * 180 / math.pi;
}

/// GeoJSON Polygon coordinates for the view wedge: the station, then an
/// arc across the field of view at [extentM] metres.
///
/// [bearingDeg] is compass degrees (0 = north, clockwise), the same
/// convention `photo_points.bearing_deg` stores.
List<List<double>> viewWedge({
  required double lat,
  required double lng,
  required double bearingDeg,
  double? focalLengthMm,
  double extentM = 60,
  int steps = 12,
}) {
  final fov = fovDegFor(focalLengthMm);
  final half = fov / 2;
  // Metres → degrees at this latitude.
  final dLat = extentM / 111320.0;
  final dLng = extentM / (111320.0 * math.cos(lat * math.pi / 180).abs());
  final pts = <List<double>>[
    [lng, lat],
  ];
  for (var i = 0; i <= steps; i++) {
    final a = (bearingDeg - half) + (fov * i / steps);
    final rad = a * math.pi / 180;
    // Compass bearing: north is +lat, east is +lng.
    pts.add([lng + dLng * math.sin(rad), lat + dLat * math.cos(rad)]);
  }
  pts.add([lng, lat]);
  return pts;
}

/// The centre line of the view — drawn over the wedge so the aim reads
/// even where two wedges overlap.
List<List<double>> viewAxis({
  required double lat,
  required double lng,
  required double bearingDeg,
  double extentM = 60,
}) {
  final rad = bearingDeg * math.pi / 180;
  final dLat = extentM / 111320.0;
  final dLng = extentM / (111320.0 * math.cos(lat * math.pi / 180).abs());
  return [
    [lng, lat],
    [lng + dLng * math.sin(rad), lat + dLat * math.cos(rad)],
  ];
}
