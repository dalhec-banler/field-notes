import 'package:field_notes/map/record_clusters.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> pt(String id, double lat, double lng) => {
  'type': 'Feature',
  'geometry': {
    'type': 'Point',
    'coordinates': [lng, lat],
  },
  'properties': {'id': id},
};

/// The map's own clustering (Austin's 1–5): nearby pins merge at low zoom,
/// split as you zoom in, and truly coincident pins never split — that is
/// when the "what's here" sheet takes over.
void main() {
  test('far-apart records stay separate at property zoom', () {
    final g = clusterFeatures([
      pt('a', 31.06, -98.05),
      pt('b', 31.07, -98.03),
    ], 16);
    expect(g.length, 2);
  });

  test('close records merge at low zoom and split at high zoom', () {
    final f = [pt('a', 31.0600, -98.0500), pt('b', 31.0602, -98.0502)];
    expect(clusterFeatures(f, 14).length, 1);
    expect(clusterFeatures(f, 19).length, 2);
    final z = expansionZoom(f, 14)!;
    expect(z, greaterThan(14));
    expect(z, lessThanOrEqualTo(19));
    expect(clusterFeatures(f, z).length, 2);
  });

  test('coincident records never split: expansion zoom is null', () {
    final f = [
      pt('a', 31.06, -98.05),
      pt('b', 31.06, -98.05),
      pt('c', 31.06, -98.05),
    ];
    expect(expansionZoom(f, 15), isNull);
    final g = clusterFeatures(f, 20);
    expect(g.single.ids, ['a', 'b', 'c']);
    expect(g.single.isCluster, isTrue);
    final (lat, lng) = g.single.centre;
    expect(lat, closeTo(31.06, 1e-9));
    expect(lng, closeTo(-98.05, 1e-9));
  });
}
