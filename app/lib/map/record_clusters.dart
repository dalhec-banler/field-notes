import '../export/web_mercator.dart';

/// Dart-side clustering for the record pins. The map plugin gives us no
/// cluster inspection, so the map screen groups pins itself on every camera
/// idle: records within one screen cell at the current zoom become one
/// badge with a count. Pure and host-testable.
class ClusterGroup {
  ClusterGroup(this.members);
  final List<Map<String, dynamic>> members;

  bool get isCluster => members.length > 1;

  /// Mean position of the members.
  (double lat, double lng) get centre {
    var lat = 0.0, lng = 0.0;
    for (final m in members) {
      final c = (m['geometry'] as Map)['coordinates'] as List;
      lng += (c[0] as num).toDouble();
      lat += (c[1] as num).toDouble();
    }
    return (lat / members.length, lng / members.length);
  }

  List<String> get ids => [
    for (final m in members) (m['properties'] as Map)['id'] as String,
  ];
}

(double lat, double lng) _coords(Map<String, dynamic> f) {
  final c = (f['geometry'] as Map)['coordinates'] as List;
  return ((c[1] as num).toDouble(), (c[0] as num).toDouble());
}

/// Group [features] into screen cells of [cellPx] at [zoom].
List<ClusterGroup> clusterFeatures(
  List<Map<String, dynamic>> features,
  double zoom, {
  double cellPx = 26,
}) {
  final z = zoom.floor();
  final scale = 1 << 0; // world px at integer zoom; fractional zoom below
  final frac = zoom - z;
  final cells = <(int, int), ClusterGroup>{};
  for (final f in features) {
    final (lat, lng) = _coords(f);
    var (x, y) = project(lat, lng, z);
    // Fractional zoom scales the world; cells should follow the screen.
    final k = _pow2(frac) * scale;
    x *= k;
    y *= k;
    final key = ((x / cellPx).floor(), (y / cellPx).floor());
    (cells[key] ??= ClusterGroup([])).members.add(f);
  }
  return cells.values.toList();
}

double _pow2(double v) => v == 0 ? 1 : _exp2(v);
double _exp2(double v) {
  // 2^v for v in [0,1): good enough with a short series, no dart:math.
  const ln2 = 0.6931471805599453;
  final x = v * ln2;
  var term = 1.0, sum = 1.0;
  for (var i = 1; i < 12; i++) {
    term *= x / i;
    sum += term;
  }
  return sum;
}

/// The first zoom above [fromZoom] at which [members] stop sharing a cell,
/// or null when they never do (coincident points) up to [maxZoom]. That is
/// the "Zillow" move: tap a cluster, land at the zoom where it splits.
double? expansionZoom(
  List<Map<String, dynamic>> members,
  double fromZoom, {
  double maxZoom = 20,
  double cellPx = 26,
}) {
  if (members.length < 2) return null;
  for (var z = fromZoom.floorToDouble() + 1; z <= maxZoom; z += 1) {
    if (clusterFeatures(members, z, cellPx: cellPx).length > 1) return z;
  }
  return null;
}
