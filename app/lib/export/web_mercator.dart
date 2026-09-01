import 'dart:math' as math;

/// Web Mercator (EPSG:3857) tile arithmetic for the map plate. Pure math —
/// no I/O, no Flutter — so the plate's framing is host-testable.
///
/// Pixel space is the standard 256 px tile grid at zoom [z]; a plate is
/// rendered in that space and then cropped to its bounding box.
class LatLngBounds {
  const LatLngBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final double south, west, north, east;

  bool get isValid => north > south && east > west;

  /// Grow by [fraction] of each dimension (a margin around the subject).
  LatLngBounds pad(double fraction) {
    final dLat = (north - south) * fraction;
    final dLng = (east - west) * fraction;
    return LatLngBounds(
      south: south - dLat,
      west: west - dLng,
      north: north + dLat,
      east: east + dLng,
    );
  }

  /// The smallest box holding every coordinate; null when there are none.
  static LatLngBounds? ofPoints(Iterable<(double lat, double lng)> points) {
    double? s, w, n, e;
    for (final (lat, lng) in points) {
      s = s == null ? lat : math.min(s, lat);
      n = n == null ? lat : math.max(n, lat);
      w = w == null ? lng : math.min(w, lng);
      e = e == null ? lng : math.max(e, lng);
    }
    if (s == null) return null;
    // A single point still needs area to frame.
    if (n! - s < 1e-6) {
      s -= 0.0015;
      n += 0.0015;
    }
    if (e! - w! < 1e-6) {
      w -= 0.0015;
      e += 0.0015;
    }
    return LatLngBounds(south: s, west: w, north: n, east: e);
  }
}

const tileSize = 256.0;

/// World pixel x/y for a coordinate at zoom [z].
(double x, double y) project(double lat, double lng, int z) {
  final n = tileSize * (1 << z);
  final x = (lng + 180) / 360 * n;
  final latRad = lat * math.pi / 180;
  final y =
      (1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) / 2 * n;
  return (x, y);
}

/// Inverse of [project].
(double lat, double lng) unproject(double x, double y, int z) {
  final n = tileSize * (1 << z);
  final lng = x / n * 360 - 180;
  final latRad = math.atan(_sinh(math.pi * (1 - 2 * y / n)));
  return (latRad * 180 / math.pi, lng);
}

double _sinh(double v) => (math.exp(v) - math.exp(-v)) / 2;

/// The zoom at which [bounds] fits in [widthPx] × [heightPx], capped at
/// [maxZoom] (imagery services stop somewhere; USGS national coverage ends
/// around 16 with deeper tiles only in places).
int zoomFor(
  LatLngBounds bounds,
  double widthPx,
  double heightPx, {
  int maxZoom = 16,
  int minZoom = 3,
}) {
  for (var z = maxZoom; z > minZoom; z--) {
    final (x0, y0) = project(bounds.north, bounds.west, z);
    final (x1, y1) = project(bounds.south, bounds.east, z);
    if ((x1 - x0).ceil() <= widthPx && (y1 - y0).ceil() <= heightPx) {
      return z;
    }
  }
  return minZoom;
}

/// Metres per pixel at the plate's centre latitude — the scale bar's input.
double metresPerPixel(double lat, int z) =>
    156543.03392 * math.cos(lat * math.pi / 180) / (1 << z);

/// A round scale-bar length (metres) that fits in about [maxPx] pixels.
(double metres, double px) scaleBar(double lat, int z, {double maxPx = 220}) {
  final mpp = metresPerPixel(lat, z);
  const candidates = [
    10.0,
    20.0,
    50.0,
    100.0,
    200.0,
    250.0,
    500.0,
    1000.0,
    2000.0,
    5000.0,
    10000.0,
    20000.0,
    50000.0,
  ];
  var best = candidates.first;
  for (final c in candidates) {
    if (c / mpp <= maxPx) best = c;
  }
  return (best, best / mpp);
}

/// The plate's frame: which tiles to fetch and where its pixel origin is.
class PlateFrame {
  PlateFrame({required this.bounds, required this.zoom}) {
    final (x0, y0) = project(bounds.north, bounds.west, zoom);
    final (x1, y1) = project(bounds.south, bounds.east, zoom);
    originX = x0;
    originY = y0;
    width = (x1 - x0).ceil();
    height = (y1 - y0).ceil();
    tileX0 = (x0 / tileSize).floor();
    tileY0 = (y0 / tileSize).floor();
    tileX1 = ((x1 - 1) / tileSize).floor();
    tileY1 = ((y1 - 1) / tileSize).floor();
  }

  final LatLngBounds bounds;
  final int zoom;
  late final double originX, originY;
  late final int width, height;
  late final int tileX0, tileY0, tileX1, tileY1;

  int get tileCount => (tileX1 - tileX0 + 1) * (tileY1 - tileY0 + 1);

  /// Plate-local pixel for a coordinate.
  (double x, double y) toPlate(double lat, double lng) {
    final (x, y) = project(lat, lng, zoom);
    return (x - originX, y - originY);
  }

  /// Plate-local top-left of a tile.
  (double x, double y) tileOrigin(int tx, int ty) =>
      (tx * tileSize - originX, ty * tileSize - originY);

  Iterable<(int x, int y)> get tiles sync* {
    for (var ty = tileY0; ty <= tileY1; ty++) {
      for (var tx = tileX0; tx <= tileX1; tx++) {
        yield (tx, ty);
      }
    }
  }
}
