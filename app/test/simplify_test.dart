import 'package:field_notes/geo/simplify.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps endpoints and drops collinear points', () {
    // Straight north walk with tiny jitter well under 5 m.
    final points = [
      for (var i = 0; i <= 20; i++) [-98.18 + i * 0.0000001, 31.05 + i * 0.0001]
    ];
    final simplified = simplifyTrack(points);
    expect(simplified.length, lessThan(5));
    expect(simplified.first, points.first);
    expect(simplified.last, points.last);
  });

  test('keeps a real corner', () {
    final points = [
      [-98.18, 31.05],
      [-98.18, 31.051], // north
      [-98.18, 31.052],
      [-98.179, 31.052], // sharp turn east
      [-98.178, 31.052],
    ];
    final simplified = simplifyTrack(points);
    // The corner point must survive.
    expect(simplified, anyElement(equals([-98.18, 31.052])));
  });

  test('path length ≈ 111 m per 0.001° latitude', () {
    final len = pathLengthM([
      [-98.18, 31.05],
      [-98.18, 31.051],
    ]);
    expect(len, closeTo(111.2, 1.0));
  });

  test('bearing: due north = 0, due east = 90', () {
    expect(bearingDeg([-98.18, 31.05], [-98.18, 31.06]), closeTo(0, 0.5));
    expect(bearingDeg([-98.18, 31.05], [-98.17, 31.05]), closeTo(90, 1.0));
  });
}
