/// Acreage from GeoJSON polygons — the zone table's fallback when an import
/// arrived without `area_acres`, and the polygon editor's live readout.
/// Pure math; the one Diag call is for a string that would not parse.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../services/diag.dart';

/// Acres from a Polygon/MultiPolygon GeoJSON string, or null if it can't
/// be read. Used when a zone arrived without `area_acres` (KML import).
/// Spherical excess per ring (Chamberlain & Duquette, the same formula
/// turf uses); holes subtract.
double? acresOf(String geojson) {
  try {
    final g = jsonDecode(geojson) as Map<String, dynamic>;
    double polygon(List rings) {
      var a = 0.0;
      for (var i = 0; i < rings.length; i++) {
        final r = _ringAreaM2(rings[i] as List);
        a += i == 0 ? r : -r;
      }
      return a;
    }

    final m2 = switch (g['type']) {
      'Polygon' => polygon(g['coordinates'] as List),
      'MultiPolygon' => [
        for (final p in g['coordinates'] as List) polygon(p as List),
      ].fold(0.0, (a, b) => a + b),
      _ => double.nan,
    };
    if (m2.isNaN || m2 <= 0) return null;
    return m2 / 4046.8564224;
  } catch (e, st) {
    Diag.report(e, st, where: 'acres.acresOf');
    return null;
  }
}

/// Acres of one ring given as `[lng, lat]` pairs (open or closed) — the
/// polygon editor's live readout, skipping the GeoJSON round trip.
double? acresOfRing(List<List<double>> ring) {
  final m2 = _ringAreaM2(ring);
  if (m2.isNaN || m2 <= 0) return null;
  return m2 / 4046.8564224;
}

double _ringAreaM2(List ring) {
  const radius = 6378137.0;
  final n = ring.length;
  if (n < 3) return 0;
  var total = 0.0;
  for (var i = 0; i < n; i++) {
    final p1 = ring[i] as List;
    final p2 = ring[(i + 1) % n] as List;
    final p3 = ring[(i + 2) % n] as List;
    final lon1 = (p1[0] as num).toDouble() * math.pi / 180;
    final lat2 = (p2[1] as num).toDouble() * math.pi / 180;
    final lon3 = (p3[0] as num).toDouble() * math.pi / 180;
    total += (lon3 - lon1) * math.sin(lat2);
  }
  return (total * radius * radius / 2).abs();
}
