import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/ids.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4a acceptance (SYNC-DESIGN): two devices, one shared folder, no
/// server. Writes captured by triggers, carried as append-only batches,
/// merged row-level last-writer-wins with a device tiebreak; idempotent.
void main() {
  late FieldNotesDb a, b;
  late OpLog logA, logB;
  late Directory work;
  late DirectoryTarget store;

  Future<String> seedProperty(FieldNotesDb db, {String name = 'Place'}) async {
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: id,
            name: name,
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<String> addObservation(
    FieldNotesDb db,
    String propId, {
    String? notes,
    String? at,
  }) async {
    final now = at ?? nowUtcIso();
    final id = newId();
    await db
        .into(db.observations)
        .insert(
          ObservationsCompanion.insert(
            id: id,
            propertyId: propId,
            observedAt: now,
            localTz: 'America/Chicago',
            lat: 31.06,
            lng: -98.05,
            notes: Value(notes),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  setUp(() async {
    a = FieldNotesDb.forTesting();
    b = FieldNotesDb.forTesting();
    logA = await OpLog.install(a, deviceId: 'device-a');
    logB = await OpLog.install(b, deviceId: 'device-b');
    work = Directory.systemTemp.createTempSync('oplog');
    store = DirectoryTarget(work);
  });

  tearDown(() async {
    await a.close();
    await b.close();
    work.deleteSync(recursive: true);
  });

  test(
    'a record born on A appears on B, child before parent tolerated',
    () async {
      final propId = await seedProperty(a, name: 'Shorts');
      final obsId = await addObservation(a, propId, notes: 'first');
      expect(await logA.pendingCount, greaterThanOrEqualTo(2));
      expect(await logA.push(store), greaterThanOrEqualTo(2));
      final res = await logB.pull(store);
      expect(res.applied, greaterThanOrEqualTo(2));

      final obs = await (b.select(
        b.observations,
      )..where((o) => o.id.equals(obsId))).getSingle();
      expect(obs.notes, 'first');
      final prop = await (b.select(
        b.properties,
      )..where((p) => p.id.equals(propId))).getSingle();
      expect(prop.name, 'Shorts');
    },
  );

  test('concurrent edits: the newer updated_at wins on both sides', () async {
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    await logA.push(store);
    await logB.pull(store);

    // B edits later than A: B's note must win everywhere.
    await (a.update(a.observations)..where((o) => o.id.equals(obsId))).write(
      ObservationsCompanion(
        notes: const Value('A says'),
        updatedAt: const Value('2026-09-01T10:00:00.000Z'),
      ),
    );
    await (b.update(b.observations)..where((o) => o.id.equals(obsId))).write(
      ObservationsCompanion(
        notes: const Value('B says'),
        updatedAt: const Value('2026-09-01T11:00:00.000Z'),
      ),
    );
    await logA.push(store);
    await logB.push(store);
    await logA.pull(store);
    await logB.pull(store);

    final onA = await (a.select(
      a.observations,
    )..where((o) => o.id.equals(obsId))).getSingle();
    final onB = await (b.select(
      b.observations,
    )..where((o) => o.id.equals(obsId))).getSingle();
    expect(onA.notes, 'B says');
    expect(onB.notes, 'B says');
  });

  test(
    'equal timestamps break by device id, identically on both sides',
    () async {
      final propId = await seedProperty(a);
      final obsId = await addObservation(a, propId);
      await logA.push(store);
      await logB.pull(store);
      const ts = '2026-09-01T12:00:00.000Z';
      await (a.update(a.observations)..where((o) => o.id.equals(obsId))).write(
        ObservationsCompanion(
          notes: const Value('from A'),
          updatedAt: const Value(ts),
        ),
      );
      await (b.update(b.observations)..where((o) => o.id.equals(obsId))).write(
        ObservationsCompanion(
          notes: const Value('from B'),
          updatedAt: const Value(ts),
        ),
      );
      await logA.push(store);
      await logB.push(store);
      await logA.pull(store);
      await logB.pull(store);
      final onA = await (a.select(
        a.observations,
      )..where((o) => o.id.equals(obsId))).getSingle();
      final onB = await (b.select(
        b.observations,
      )..where((o) => o.id.equals(obsId))).getSingle();
      expect(onA.notes, onB.notes, reason: 'tiebreak must be deterministic');
    },
  );

  test('a hard delete travels as a tombstone', () async {
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    await logA.push(store);
    await logB.pull(store);
    await (a.delete(a.observations)..where((o) => o.id.equals(obsId))).go();
    await logA.push(store);
    await logB.pull(store);
    final gone = await (b.select(
      b.observations,
    )..where((o) => o.id.equals(obsId))).getSingleOrNull();
    expect(gone, isNull);
  });

  test(
    'pull is idempotent and applying never re-captures as local ops',
    () async {
      final propId = await seedProperty(a);
      await addObservation(a, propId);
      await logA.push(store);
      final first = await logB.pull(store);
      expect(first.applied, greaterThan(0));
      // B captured nothing while applying: nothing to push back but its own
      // writes (none).
      expect(await logB.pendingCount, 0);
      final again = await logB.pull(store);
      expect(again.applied, 0);
    },
  );

  test('push is incremental: a second push writes only what is new', () async {
    final propId = await seedProperty(a);
    await logA.push(store);
    expect(await logA.push(store), 0);
    await addObservation(a, propId);
    expect(await logA.push(store), 1);
    final files = await store.list('sync/device-a');
    expect(files.length, 2);
  });
}
