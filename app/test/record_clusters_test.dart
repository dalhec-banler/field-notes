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

  test('the desk groups plate-shaped items the way the phone groups pins', () {
    // Same points as GeoJSON and as bare records: identical cells, so the
    // two maps badge the same clusters at the same zoom.
    final asFeatures = [
      pt('a', 31.06, -98.05),
      pt('b', 31.0605, -98.0505),
      pt('c', 31.10, -98.10),
    ];
    final asRecords = [
      ('a', 31.06, -98.05),
      ('b', 31.0605, -98.0505),
      ('c', 31.10, -98.10),
    ];
    (double, double) coords((String, double, double) r) => (r.$2, r.$3);
    for (final z in [11.0, 13.5, 16.0]) {
      final phone = clusterFeatures(
        asFeatures,
        z,
      ).map((g) => g.ids.join(',')).toSet();
      final desk = clusterBy(
        asRecords,
        coords,
        z,
      ).map((c) => c.map((r) => r.$1).join(',')).toSet();
      expect(desk, phone, reason: 'zoom $z');
    }
    final ab = asRecords.sublist(0, 2);
    expect(
      expansionZoomBy(ab, coords, 11),
      expansionZoom(asFeatures.sublist(0, 2), 11),
    );
    final (lat, lng) = centreOf(ab, coords);
    expect(lat, closeTo(31.06025, 1e-9));
    expect(lng, closeTo(-98.05025, 1e-9));
  });
}
