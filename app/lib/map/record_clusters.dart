import 'dart:math' as math;

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
  (double lat, double lng) get centre => centreOf(members, _coords);

  List<String> get ids => [
    for (final m in members) (m['properties'] as Map)['id'] as String,
  ];
}

(double lat, double lng) _coords(Map<String, dynamic> f) {
  final c = (f['geometry'] as Map)['coordinates'] as List;
  return ((c[1] as num).toDouble(), (c[0] as num).toDouble());
}

/// Group [items] into screen cells of [cellPx] at [zoom]; [coordsOf] gives
/// each item's (lat, lng). The one clusterer: the phone feeds it GeoJSON
/// features, the desk map feeds it plate records, and both draw the same
/// badges because both group the same way.
List<List<T>> clusterBy<T>(
  Iterable<T> items,
  (double lat, double lng) Function(T) coordsOf,
  double zoom, {
  double cellPx = 26,
}) {
  final z = zoom.floor();
  // Fractional zoom scales the world; cells should follow the screen.
  final k = math.pow(2.0, zoom - z).toDouble();
  final cells = <(int, int), List<T>>{};
  for (final item in items) {
    final (lat, lng) = coordsOf(item);
    final (x, y) = project(lat, lng, z);
    final key = ((x * k / cellPx).floor(), (y * k / cellPx).floor());
    (cells[key] ??= []).add(item);
  }
  return cells.values.toList();
}

/// Mean position of [items].
(double lat, double lng) centreOf<T>(
  Iterable<T> items,
  (double lat, double lng) Function(T) coordsOf,
) {
  var lat = 0.0, lng = 0.0, n = 0;
  for (final item in items) {
    final c = coordsOf(item);
    lat += c.$1;
    lng += c.$2;
    n++;
  }
  return (lat / n, lng / n);
}

/// Group [features] into screen cells of [cellPx] at [zoom].
List<ClusterGroup> clusterFeatures(
  List<Map<String, dynamic>> features,
  double zoom, {
  double cellPx = 26,
}) => [
  for (final cell in clusterBy(features, _coords, zoom, cellPx: cellPx))
    ClusterGroup(cell),
];

/// Badge display conventions, one home: the label the badge draws and the
/// icon-cache key the map screen uses must cap at 99+ together, or cached
/// icons mislabel.
String clusterLabel(int count) => count > 99 ? '99+' : '$count';

String clusterIconKey(int count) => 'cluster-${count > 99 ? '99plus' : count}';

/// Where a tapped cluster lands: a fraction past the integer zoom, so the
/// badge just clicked isn't sitting on the cell boundary.
const clusterLanding = 0.4;

/// The first landing zoom above [fromZoom] at which [members] stop sharing
/// a cell, or null when they never do (coincident points, or closer than
/// [maxZoom] can separate). That is the "Zillow" move: tap a cluster, land
/// at the zoom where it splits. The zoom returned is the one to land on —
/// the lattice is tested there, not at the integer below it (a split found
/// at z and landed at z+0.4 re-merged about one click in ten).
double? expansionZoom(
  List<Map<String, dynamic>> members,
  double fromZoom, {
  double maxZoom = 20,
  double cellPx = 26,
}) => expansionZoomBy(
  members,
  _coords,
  fromZoom,
  maxZoom: maxZoom,
  cellPx: cellPx,
);

/// [expansionZoom] for any item type.
double? expansionZoomBy<T>(
  List<T> members,
  (double lat, double lng) Function(T) coordsOf,
  double fromZoom, {
  double maxZoom = 20,
  double cellPx = 26,
}) {
  if (members.length < 2) return null;
  for (
    var z = fromZoom.floorToDouble() + clusterLanding;
    z <= maxZoom + clusterLanding;
    z += 1
  ) {
    if (z <= fromZoom) continue;
    if (clusterBy(members, coordsOf, z, cellPx: cellPx).length > 1) return z;
  }
  return null;
}
