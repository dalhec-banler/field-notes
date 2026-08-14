import 'package:drift/drift.dart' hide isNull;
import 'package:field_notes/db/database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FieldNotesDb db;

  setUp(() => db = FieldNotesDb.forTesting());
  tearDown(() => db.close());

  test('schema creates and round-trips a property + observation', () async {
    final now = nowUtcIso();
    final propId = newId();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
          id: propId,
          name: 'Shorts Resort',
          createdBy: 'austin',
          createdAt: now,
          updatedAt: now,
          landTenure: const Value('owned'),
        ));

    final obsId = newId();
    await db.into(db.observations).insert(ObservationsCompanion.insert(
          id: obsId,
          propertyId: propId,
          observedAt: now,
          localTz: 'CDT',
          lat: 31.06,
          lng: -98.18,
          createdBy: 'austin',
          createdAt: now,
          updatedAt: now,
        ));

    final obs = await (db.select(db.observations)
          ..where((o) => o.id.equals(obsId)))
        .getSingle();
    expect(obs.propertyId, propId);
    expect(obs.observationType, 'general');
    expect(obs.deletedAt, isNull);
  });

  test('land_tenure CHECK rejects invalid values', () async {
    final now = nowUtcIso();
    expect(
      () => db.into(db.properties).insert(PropertiesCompanion.insert(
            id: newId(),
            name: 'Bad tenure',
            createdBy: 'austin',
            createdAt: now,
            updatedAt: now,
            landTenure: const Value('rented'),
          )),
      throwsA(anything),
    );
  });

  test('foreign keys are enforced', () async {
    final now = nowUtcIso();
    expect(
      () => db.into(db.observations).insert(ObservationsCompanion.insert(
            id: newId(),
            propertyId: 'no-such-property',
            observedAt: now,
            localTz: 'CDT',
            lat: 0,
            lng: 0,
            createdBy: 'austin',
            createdAt: now,
            updatedAt: now,
          )),
      throwsA(anything),
    );
  });

  test('ids are UUIDv7 and time-ordered across milliseconds', () async {
    final a = newId();
    // v7 is time-ordered at millisecond granularity; intra-ms order is random.
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final b = newId();
    expect(a, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-')));
    expect(a.compareTo(b), lessThan(0));
  });
}
