import 'package:field_notes/export/web_mercator.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plate's framing math (D-024 exports). If these are wrong, every
/// polygon lands on the wrong pixel of the imagery underneath.
void main() {
  test('project/unproject round-trip', () {
    for (final z in [3, 10, 16]) {
      final (x, y) = project(31.0618, -98.0482, z);
      final (lat, lng) = unproject(x, y, z);
      expect(lat, closeTo(31.0618, 1e-6));
      expect(lng, closeTo(-98.0482, 1e-6));
    }
  });

  test('project anchors: origin at the centre, ±85.05° at the edges', () {
    for (final z in [0, 5, 12]) {
      final n = tileSize * (1 << z);
      final (cx, cy) = project(0, 0, z);
      expect(cx, closeTo(n / 2, 1e-6));
      expect(cy, closeTo(n / 2, 1e-6));
      final (_, top) = project(85.05112878, -180, z);
      expect(top, closeTo(0, 1e-3));
      final (right, bottom) = project(-85.05112878, 180, z);
      expect(right, closeTo(n, 1e-6));
      expect(bottom, closeTo(n, 1e-3));
    }
    // North is up: a higher latitude has a smaller y.
    expect(project(32, -98, 10).$2, lessThan(project(31, -98, 10).$2));
  });

  test('bounds of points pads a single point into a frameable box', () {
    final b = LatLngBounds.ofPoints([(31.0, -98.0)])!;
    expect(b.isValid, isTrue);
    expect(b.north - b.south, greaterThan(0.001));
  });

  test('zoomFor picks the deepest zoom that fits and honours the cap', () {
    final b = const LatLngBounds(
        south: 31.05, west: -98.06, north: 31.07, east: -98.03);
    final z = zoomFor(b, 1600, 1200);
    expect(z, 16); // ~2.9 km wide fits comfortably at 16
    final small = zoomFor(b, 200, 200);
    expect(small, lessThan(z));
    expect(zoomFor(b, 4000, 4000, maxZoom: 14), 14);
  });

  test('frame tiles cover the box and toPlate maps corners to edges', () {
    final b = const LatLngBounds(
        south: 31.05, west: -98.06, north: 31.07, east: -98.03);
    final f = PlateFrame(bounds: b, zoom: 15);
    expect(f.tileCount, greaterThan(0));
    final (nwX, nwY) = f.toPlate(b.north, b.west);
    expect(nwX, closeTo(0, 1e-6));
    expect(nwY, closeTo(0, 1e-6));
    final (seX, seY) = f.toPlate(b.south, b.east);
    expect(seX, closeTo(f.width, 1.0));
    expect(seY, closeTo(f.height, 1.0));
    // Every tile origin sits within one tile of the plate.
    for (final (tx, ty) in f.tiles) {
      final (ox, oy) = f.tileOrigin(tx, ty);
      expect(ox, greaterThan(-tileSize));
      expect(oy, greaterThan(-tileSize));
      expect(ox, lessThan(f.width));
      expect(oy, lessThan(f.height));
    }
  });

  test('scale bar is a round number that fits', () {
    final (m, px) = scaleBar(31.06, 16);
    expect([100.0, 200.0, 250.0, 500.0], contains(m));
    expect(px, lessThanOrEqualTo(220));
    expect(px, greaterThan(60));
  });
}
