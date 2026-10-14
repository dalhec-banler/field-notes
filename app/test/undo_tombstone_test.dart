import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/observation_ops.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-038 item 12 (SYNC-DESIGN, "one real casualty"): once a record's
/// insert has been pushed, UNDO is a tombstone the peer will apply; while
/// it has not, UNDO is the hard erase, and the pending ops go with it so
/// the peer never hears the record existed.
void main() {
  late FieldNotesDb a, b;
  late OpLog logA, logB;
  late Directory work;
  late DirectoryTarget store;

  Future<String> seedProperty(FieldNotesDb db) async {
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: id,
            name: 'Shorts',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<String> addObservation(FieldNotesDb db, String propId) async {
    final now = nowUtcIso();
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
            notes: const Value('a note'),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  /// A media row linked to the record, with a real file on disk.
  Future<(String, File)> addPhoto(
    FieldNotesDb db,
    String propId,
    String obsId,
  ) async {
    final now = nowUtcIso();
    final file = File('${work.path}/${newId()}.jpg')
      ..writeAsBytesSync(List<int>.filled(64, 1));
    final mediaId = newId();
    await db
        .into(db.media)
        .insert(
          MediaCompanion.insert(
            id: mediaId,
            propertyId: propId,
            mediaType: 'photo',
            localPath: Value(file.path),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.mediaLinks)
        .insert(
          MediaLinksCompanion.insert(
            id: newId(),
            propertyId: propId,
            mediaId: mediaId,
            entityType: 'observation',
            entityId: obsId,
            role: const Value('primary'),
            createdAt: now,
          ),
        );
    return (mediaId, file);
  }

  Future<int> opsFor(FieldNotesDb db, String table, String id) async {
    final r = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM sync_ops WHERE table_name = ? AND row_id = ?',
          variables: [Variable.withString(table), Variable.withString(id)],
        )
        .getSingle();
    return r.data['n'] as int;
  }

  Future<Observation?> obsOn(FieldNotesDb db, String id) =>
      (db.select(db.observations)..where((o) => o.id.equals(id)))
          .getSingleOrNull();

  setUp(() async {
    a = FieldNotesDb.forTesting();
    b = FieldNotesDb.forTesting();
    logA = await OpLog.install(a, deviceId: 'device-a');
    logB = await OpLog.install(b, deviceId: 'device-b');
    work = Directory.systemTemp.createTempSync('undo');
    store = DirectoryTarget(work);
  });

  tearDown(() async {
    await a.close();
    await b.close();
    work.deleteSync(recursive: true);
  });

  test('the op log alone does NOT forget a hard delete: put and del both travel', () async {
    // The reason the UNDO path has to drop ops itself.
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    await (a.delete(a.observations)..where((o) => o.id.equals(obsId))).go();
    expect(await opsFor(a, 'observations', obsId), 2);
    expect(await logA.hasBeenPushed('observations', obsId), isFalse);
  });

  test('not yet pushed: UNDO erases, drops the pending ops, and the peer never hears', () async {
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    final (mediaId, file) = await addPhoto(a, propId, obsId);
    expect(await logA.hasBeenPushed('observations', obsId), isFalse);

    final outcome = await undoObservation(a, obsId, log: logA);
    expect(outcome, UndoOutcome.erased);
    expect(await obsOn(a, obsId), isNull);
    expect(file.existsSync(), isFalse, reason: 'the photo file goes too');
    expect(await opsFor(a, 'observations', obsId), 0);
    expect(await opsFor(a, 'media', mediaId), 0);
    final links = await a
        .customSelect(
          "SELECT COUNT(*) AS n FROM sync_ops WHERE table_name = 'media_links'",
        )
        .getSingle();
    expect(links.data['n'], 0);
    final versions = await a
        .customSelect(
          'SELECT COUNT(*) AS n FROM sync_versions WHERE row_id = ?',
          variables: [Variable.withString(obsId)],
        )
        .getSingle();
    expect(versions.data['n'], 0);

    // The property still travels; nothing of the record does.
    expect(await logA.push(store, allowPlaintext: true), 1);
    final res = await logB.pull(store, allowPlaintext: true);
    expect(res.applied, 1);
    expect(await obsOn(b, obsId), isNull);
    final vb = await b
        .customSelect(
          'SELECT COUNT(*) AS n FROM sync_versions WHERE row_id = ?',
          variables: [Variable.withString(obsId)],
        )
        .getSingle();
    expect(vb.data['n'], 0, reason: 'B never learned the row existed');
  });

  test('already pushed: UNDO becomes a tombstone the peer applies', () async {
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    final (_, file) = await addPhoto(a, propId, obsId);
    await logA.push(store, allowPlaintext: true);
    await logB.pull(store, allowPlaintext: true);
    expect(await obsOn(b, obsId), isNotNull);
    expect(await logA.hasBeenPushed('observations', obsId), isTrue);

    final outcome = await undoObservation(a, obsId, log: logA);
    expect(outcome, UndoOutcome.tombstoned);
    final onA = await obsOn(a, obsId);
    expect(onA, isNotNull, reason: 'soft delete keeps the row');
    expect(onA!.deletedAt, isNotNull);
    expect(file.existsSync(), isTrue, reason: 'a tombstone keeps the photo');

    await logA.push(store, allowPlaintext: true);
    await logB.pull(store, allowPlaintext: true);
    final onB = await obsOn(b, obsId);
    expect(onB, isNotNull);
    expect(onB!.deletedAt, onA.deletedAt);
  });

  test('pushed to a shared property store counts as pushed', () async {
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    await logA.push(
      store,
      allowPlaintext: true,
      scope: SyncScope.property(propId),
    );
    expect(await logA.hasBeenPushed('observations', obsId), isTrue);
    expect(await undoObservation(a, obsId, log: logA), UndoOutcome.tombstoned);
  });

  test('a row that arrived from a peer counts as pushed: its writer has it', () async {
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    await logA.push(store, allowPlaintext: true);
    await logB.pull(store, allowPlaintext: true);
    expect(await logB.hasBeenPushed('observations', obsId), isTrue);
    expect(await undoObservation(b, obsId, log: logB), UndoOutcome.tombstoned);
  });

  test('a mixed erase keeps the ops of what some store has seen', () async {
    // The record was pushed; a photo was added afterwards and not pushed.
    // A hard erase of both must still send the record's tombstone.
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    await logA.push(store, allowPlaintext: true);
    await logB.pull(store, allowPlaintext: true);
    final (mediaId, _) = await addPhoto(a, propId, obsId);

    await eraseObservation(a, obsId, log: logA);
    expect(await opsFor(a, 'media', mediaId), 0, reason: 'never seen: gone');
    expect(
      await opsFor(a, 'observations', obsId),
      2,
      reason: 'seen: insert stays below the mark, tombstone waits above it',
    );
    await logA.push(store, allowPlaintext: true);
    await logB.pull(store, allowPlaintext: true);
    expect(await obsOn(b, obsId), isNull);
  });

  test('with no op log at all, UNDO is the plain erase', () async {
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    expect(await undoObservation(a, obsId), UndoOutcome.erased);
    expect(await obsOn(a, obsId), isNull);
  });

  test('eraseMedia drops the ops of an unpushed photo and keeps a pushed one\'s', () async {
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    final (fresh, _) = await addPhoto(a, propId, obsId);
    await eraseMedia(a, fresh, log: logA);
    expect(await opsFor(a, 'media', fresh), 0);

    final (sent, _) = await addPhoto(a, propId, obsId);
    await logA.push(store, allowPlaintext: true);
    await eraseMedia(a, sent, log: logA);
    expect(await opsFor(a, 'media', sent), 2);
  });
}
