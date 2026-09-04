import 'package:drift/drift.dart' hide isNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/survival.dart';
import 'package:field_notes/services/tag_codes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('nextTagCode', () {
    test('increments preserving zero padding', () {
      expect(nextTagCode('SFS-BW-040'), 'SFS-BW-041');
      expect(nextTagCode('SFS-BW-009'), 'SFS-BW-010');
      expect(nextTagCode('T7'), 'T8');
      expect(nextTagCode('99'), '100');
    });

    test('returns null without a trailing number', () {
      expect(nextTagCode('riverbank-willow'), isNull);
      expect(nextTagCode(''), isNull);
      expect(nextTagCode(null), isNull);
    });
  });

  group('survival (spec §8 M2 acceptance)', () {
    late FieldNotesDb db;
    late String propId;
    late PlantingEvent event;

    setUp(() async {
      db = FieldNotesDb.forTesting();
      final now = nowUtcIso();
      propId = newId();
      await db
          .into(db.properties)
          .insert(
            PropertiesCompanion.insert(
              id: propId,
              name: 'SFS',
              createdBy: 'a',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final eventId = newId();
      // December planting of 40 black willow cuttings.
      await db
          .into(db.plantingEvents)
          .insert(
            PlantingEventsCompanion.insert(
              id: eventId,
              propertyId: propId,
              plantedOn: '2026-12-15',
              stockSource: 'own_propagation',
              countPlanted: 40,
              createdBy: 'a',
              createdAt: now,
              updatedAt: now,
            ),
          );
      event = await (db.select(
        db.plantingEvents,
      )..where((e) => e.id.equals(eventId))).getSingle();
    });

    tearDown(() => db.close());

    test('no check-ins yet → null, not 100%', () async {
      expect(await survivalFor(db, event), isNull);
    });

    test('cohort-level check-in: March check finds 31 alive', () async {
      final now = nowUtcIso();
      await db
          .into(db.plantCheckins)
          .insert(
            PlantCheckinsCompanion.insert(
              id: newId(),
              propertyId: propId,
              plantingEventId: Value(event.id),
              checkedAt: '2027-03-10T10:00:00Z',
              status: 'alive',
              countAlive: const Value(31),
              countDead: const Value(9),
              createdBy: 'a',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final s = await survivalFor(db, event);
      expect(s!.alive, 31);
      expect(s.total, 40);
      expect(s.source, 'cohort_checkin');
      expect(s.rate, closeTo(0.775, 0.001));
    });

    test('latest cohort check-in wins over older ones', () async {
      final now = nowUtcIso();
      for (final (checkedAt, alive) in [
        ('2027-03-10T10:00:00Z', 31),
        ('2027-06-01T10:00:00Z', 28),
      ]) {
        await db
            .into(db.plantCheckins)
            .insert(
              PlantCheckinsCompanion.insert(
                id: newId(),
                propertyId: propId,
                plantingEventId: Value(event.id),
                checkedAt: checkedAt,
                status: 'alive',
                countAlive: Value(alive),
                createdBy: 'a',
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      expect((await survivalFor(db, event))!.alive, 28);
    });

    test('tagged individuals override cohort check-ins', () async {
      final now = nowUtcIso();
      // 4 individuals: 2 alive, 1 browsed (counts as alive), 1 dead.
      for (final (tag, status) in [
        ('SFS-BW-001', 'alive'),
        ('SFS-BW-002', 'alive'),
        ('SFS-BW-003', 'browsed'),
        ('SFS-BW-004', 'dead'),
      ]) {
        await db
            .into(db.plants)
            .insert(
              PlantsCompanion.insert(
                id: newId(),
                propertyId: propId,
                plantingEventId: event.id,
                tagCode: Value(tag),
                currentStatus: Value(status),
                createdBy: 'a',
                createdAt: now,
                updatedAt: now,
              ),
            );
      }
      final s = await survivalFor(db, event);
      expect(s!.alive, 3);
      expect(s.total, 4);
      expect(s.source, 'individuals');
    });

    test('lastTagCode returns most recent for suggestion seeding', () async {
      final now = nowUtcIso();
      for (final tag in ['SFS-BW-001', 'SFS-BW-002']) {
        await db
            .into(db.plants)
            .insert(
              PlantsCompanion.insert(
                id: newId(),
                propertyId: propId,
                plantingEventId: event.id,
                tagCode: Value(tag),
                createdBy: 'a',
                createdAt: now,
                updatedAt: now,
              ),
            );
        // UUIDv7 ordering is only guaranteed across milliseconds.
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final last = await lastTagCode(db, propId);
      expect(last, 'SFS-BW-002');
      expect(nextTagCode(last), 'SFS-BW-003');
    });
  });
}
