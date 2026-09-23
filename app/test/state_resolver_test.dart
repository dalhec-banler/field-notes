import 'dart:io';

import 'package:field_notes/geo/state_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StateResolver resolver;
  setUpAll(() {
    resolver = StateResolver.fromGeoJson(
      File('assets/geo/us_states.geojson').readAsStringSync(),
    );
  });

  test('bundle covers the 50 states plus DC and PR', () {
    expect(resolver.all.length, 52);
    expect(resolver.byUsps('tx')?.name, 'Texas');
  });

  test('a Lampasas County point is Texas, not anything else', () {
    expect(resolver.stateAt(31.06, -98.05)?.usps, 'TX');
  });

  test('other states resolve from a point in the middle of them', () {
    expect(resolver.stateAt(40.4, -82.9)?.usps, 'OH'); // Columbus
    expect(resolver.stateAt(44.05, -123.09)?.usps, 'OR'); // Eugene
    expect(resolver.stateAt(64.8, -147.7)?.usps, 'AK'); // Fairbanks
    expect(resolver.stateAt(21.3, -157.86)?.usps, 'HI'); // Honolulu
  });

  test('a point in the Gulf or abroad is nobody\'s state', () {
    expect(resolver.stateAt(26.0, -92.0), isNull); // Gulf of Mexico
    expect(resolver.stateAt(51.5, -0.12), isNull); // London
  });
}
