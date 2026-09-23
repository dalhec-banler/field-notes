import 'dart:io';

import 'package:field_notes/db/database.dart';
import 'package:field_notes/geo/state_resolver.dart';
import 'package:field_notes/services/property_locator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FieldNotesDb db;
  late String propId;

  setUpAll(() async {
    // No asset bundle under test: prime the resolver from the file.
    await StateResolver.load(
      geojsonText: File('assets/geo/us_states.geojson').readAsStringSync(),
    );
  });

  setUp(() async {
    db = FieldNotesDb.forTesting();
    propId = newId();
    final now = nowUtcIso();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propId,
            name: 'Somewhere',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
  });

  tearDown(() => db.close());

  Future<Property> prop() =>
      (db.select(db.properties)..where((p) => p.id.equals(propId))).getSingle();

  test(
    'first coordinate sets centroid and state on a placeless property',
    () async {
      final state = await PropertyLocator(db).noteLocation(propId, 40.4, -82.9);
      expect(state?.usps, 'OH');
      final p = await prop();
      expect(p.centroidLat, 40.4);
      expect(p.centroidLng, -82.9);
      expect(p.state, 'OH');
    },
  );

  test(
    'a later coordinate never moves a centroid or changes a state',
    () async {
      final locator = PropertyLocator(db);
      await locator.noteLocation(propId, 31.06, -98.05);
      final state = await locator.noteLocation(propId, 40.4, -82.9);
      expect(
        state?.usps,
        'TX',
        reason: 'reports the known state, not the new point',
      );
      final p = await prop();
      expect(p.centroidLat, 31.06);
      expect(p.state, 'TX');
    },
  );

  test(
    'a boundary centre fills the state without touching the centroid',
    () async {
      await PropertyLocator(db)
          .noteLocation(propId, 44.05, -123.09, setCentroid: false);
      final p = await prop();
      expect(p.centroidLat, isNull);
      expect(p.state, 'OR');
    },
  );

  test(
    'a point outside every state leaves state null and still centres',
    () async {
      final state = await PropertyLocator(db).noteLocation(propId, 26.0, -92.0);
      expect(state, isNull);
      final p = await prop();
      expect(p.centroidLat, 26.0);
      expect(p.state, isNull);
    },
  );

  test('a picked state is written as-is', () async {
    await PropertyLocator(db).setState(propId, 'mt');
    expect((await prop()).state, 'MT');
  });
}
