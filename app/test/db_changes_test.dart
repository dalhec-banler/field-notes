import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:flutter_test/flutter_test.dart';

/// drift shares live streams by SQL text + variables and ignores
/// `readsFrom`, so every `SELECT 1` watch in the app used to collapse into
/// whichever registered first (the map's pins stopped following record
/// edits, 2026-09-08). [FieldNotesDb.changes] keys each watch by its
/// tables; this pins that.
void main() {
  late FieldNotesDb db;

  setUp(() => db = FieldNotesDb.forTesting());
  tearDown(() => db.close());

  Future<String> property() async {
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: id,
            name: 'Yard',
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  test(
    'a changes() watch follows its own tables, whoever registered first',
    () async {
      final propId = await property();
      var featureTicks = 0;
      var recordTicks = 0;
      // The trap in the order the map hits it: features first, records after.
      final features = db.changes({db.features}).listen((_) => featureTicks++);
      final records = db
          .changes({db.observations, db.taxa})
          .listen((_) => recordTicks++);
      await settle();
      expect(recordTicks, 1, reason: 'emits once on listen');
      expect(featureTicks, 1);

      final now = nowUtcIso();
      await db
          .into(db.observations)
          .insert(
            ObservationsCompanion.insert(
              id: newId(),
              propertyId: propId,
              observedAt: now,
              localTz: 'CDT',
              lat: 30.26,
              lng: -97.72,
              createdBy: 'a',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await settle();
      expect(
        recordTicks,
        2,
        reason: 'an observation write reaches the record watch',
      );
      expect(featureTicks, 1, reason: 'and not the features watch');

      await (db.update(db.observations))
          .write(const ObservationsCompanion(observationType: Value('plant')));
      await settle();
      expect(recordTicks, 3, reason: 'an edit reaches it too');

      await features.cancel();
      await records.cancel();
    },
  );
}
