import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/ids.dart';
import 'package:field_notes/id/id_models.dart';
import 'package:field_notes/id/identification_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rule 7 says retain every suggestion; v3 makes runs distinguishable:
/// each identify() writes its own run_id, and accepting a name flags it
/// only within that run — earlier runs stay as history, unflagged.
void main() {
  late FieldNotesDb db;
  late String propId;
  late Observation obs;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    final now = nowUtcIso();
    propId = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propId,
            name: 'Test Place',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final obsId = newId();
    await db
        .into(db.observations)
        .insert(
          ObservationsCompanion.insert(
            id: obsId,
            propertyId: propId,
            observedAt: now,
            localTz: 'America/Chicago',
            lat: 31.06,
            lng: -98.05,
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    obs = await (db.select(
      db.observations,
    )..where((o) => o.id.equals(obsId))).getSingle();
  });

  tearDown(() => db.close());

  final liveOak = IdCandidate(
    name: 'Quercus fusiformis',
    commonName: 'Plateau live oak',
    score: 0.72,
    source: 'plantnet',
  );
  final cedar = IdCandidate(
    name: 'Juniperus ashei',
    commonName: 'Ashe juniper',
    score: 0.18,
    source: 'plantnet',
  );

  test(
    'two runs stack with distinct run ids; accept flags only its run',
    () async {
      final svc = IdentificationService(db);
      final run1 = await svc.recordSuggestions([liveOak, cedar], obs);
      svc.lastRunId = null; // fresh run
      final run2 = await svc.recordSuggestions([liveOak, cedar], obs);
      expect(run1, isNot(run2));

      final all = await db.select(db.identificationSuggestions).get();
      expect(all, hasLength(4));
      expect(all.map((s) => s.runId).toSet(), {run1, run2});

      await svc.accept(
        candidate: liveOak,
        observationId: obs.id,
        propertyId: propId,
        runId: run2,
      );
      final accepted = await (db.select(
        db.identificationSuggestions,
      )..where((s) => s.accepted.equals(1))).get();
      expect(accepted, hasLength(1));
      expect(accepted.single.runId, run2);
      expect(accepted.single.suggestedName, 'Quercus fusiformis');

      // The record itself got the taxon, as probable.
      final after = await (db.select(
        db.observations,
      )..where((o) => o.id.equals(obs.id))).getSingle();
      expect(after.taxonId, isNotNull);
      expect(after.taxonConfidence, 'probable');
      svc.close();
    },
  );

  test('accept without a run id keeps the old by-name behaviour', () async {
    final svc = IdentificationService(db);
    await svc.recordSuggestions([liveOak], obs);
    await svc.accept(
      candidate: liveOak,
      observationId: obs.id,
      propertyId: propId,
    );
    final accepted = await (db.select(
      db.identificationSuggestions,
    )..where((s) => s.accepted.equals(1))).get();
    expect(accepted, hasLength(1));
    svc.close();
  });
}
