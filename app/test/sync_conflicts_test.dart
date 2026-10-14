import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/diag.dart';
import 'package:field_notes/sync/conflict_log.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-038 item 12: when the merge rule overrules one writer in favour of
/// another, the fact is kept — in `sync_conflicts.json`, capped — and said
/// in the diagnostics log. Re-applying one's own op is not a conflict.
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
            notes: const Value('first'),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<void> edit(FieldNotesDb db, String obsId, String notes) =>
      (db.update(db.observations)..where((o) => o.id.equals(obsId))).write(
        ObservationsCompanion(
          notes: Value(notes),
          updatedAt: Value(nowUtcIso()),
        ),
      );

  /// Both devices hold the row, pulled from A.
  Future<String> shared() async {
    final propId = await seedProperty(a);
    final obsId = await addObservation(a, propId);
    await logA.push(store, allowPlaintext: true);
    await logB.pull(store, allowPlaintext: true);
    return obsId;
  }

  setUp(() async {
    Diag.resetForTesting();
    work = Directory.systemTemp.createTempSync('conflicts');
    Diag.directoryOverride = Directory('${work.path}/diag')..createSync();
    a = FieldNotesDb.forTesting();
    b = FieldNotesDb.forTesting();
    logA = await OpLog.install(
      a,
      deviceId: 'device-a',
      conflictFile: File('${work.path}/a/sync_conflicts.json'),
    );
    logB = await OpLog.install(
      b,
      deviceId: 'device-b',
      conflictFile: File('${work.path}/b/sync_conflicts.json'),
    );
    store = DirectoryTarget(Directory('${work.path}/store')..createSync());
  });

  tearDown(() async {
    await a.close();
    await b.close();
    await Diag.flush();
    Diag.directoryOverride = null;
    work.deleteSync(recursive: true);
  });

  test('a losing incoming op lands in the conflict log, newest first', () async {
    final obsId = await shared();
    await edit(a, obsId, 'A says');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await edit(b, obsId, 'B says'); // later: B's stands
    await logA.push(store, allowPlaintext: true);
    await logB.push(store, allowPlaintext: true);

    // B receives A's older edit and keeps its own.
    await logB.pull(store, allowPlaintext: true);
    final onB = await logB.conflicts.read();
    expect(onB, hasLength(1));
    final c = onB.single;
    expect(c.table, 'observations');
    expect(c.rowId, obsId);
    expect(c.kept, isTrue);
    expect(c.winner, 'device-b');
    expect(c.loser, 'device-a');
    expect(c.fields, contains('notes'));
    expect(c.fields, isNot(contains('lat')));
    expect(c.localVersion.compareTo(c.incomingVersion), greaterThan(0));

    // On disk, beside the database.
    final file = File('${work.path}/b/sync_conflicts.json');
    expect(file.existsSync(), isTrue);
    final raw = jsonDecode(file.readAsStringSync()) as List;
    expect(raw, hasLength(1));
    expect((raw.single as Map)['row_id'], obsId);

    // And said in the diagnostics log.
    expect(
      Diag.entries.any(
        (e) => e.where == 'ConflictLog' && e.message.contains(obsId),
      ),
      isTrue,
    );

    // A receives B's newer edit. A's own edit had been pushed before B's
    // arrived, so that is a later edit landing, not a cross-over.
    await logA.pull(store, allowPlaintext: true);
    expect(await logA.conflicts.read(), isEmpty);
    final row = await (a.select(
      a.observations,
    )..where((o) => o.id.equals(obsId))).getSingle();
    expect(row.notes, 'B says');
  });

  test('an incoming win over an unsent local change is a conflict too', () async {
    final obsId = await shared();
    await edit(a, obsId, 'A, offline');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await edit(b, obsId, 'B, pushed');
    await logB.push(store, allowPlaintext: true);

    // A has not pushed; B's arrives and wins.
    await logA.pull(store, allowPlaintext: true);
    final onA = await logA.conflicts.read();
    expect(onA, hasLength(1));
    expect(onA.single.kept, isFalse);
    expect(onA.single.winner, 'device-b');
    expect(onA.single.loser, 'device-a');
    expect(onA.single.fields, contains('notes'));
    final row = await (a.select(
      a.observations,
    )..where((o) => o.id.equals(obsId))).getSingle();
    expect(row.notes, 'B, pushed');
  });

  test('a deletion that beats an unsent edit is recorded without fields', () async {
    final obsId = await shared();
    await edit(a, obsId, 'A, offline');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await (b.delete(b.observations)..where((o) => o.id.equals(obsId))).go();
    await logB.push(store, allowPlaintext: true);
    await logA.pull(store, allowPlaintext: true);
    final onA = await logA.conflicts.read();
    expect(onA, hasLength(1));
    expect(onA.single.kept, isFalse);
    expect(onA.single.fields, isEmpty);
  });

  test('ordinary additive sync and re-pulls record nothing', () async {
    final obsId = await shared();
    expect(await logB.conflicts.read(), isEmpty);
    // A later edit from one side, pulled by the other: sequential.
    await edit(a, obsId, 'A again');
    await logA.push(store, allowPlaintext: true);
    await logB.pull(store, allowPlaintext: true);
    await logB.pull(store, allowPlaintext: true);
    expect(await logB.conflicts.read(), isEmpty);
    expect(await logA.conflicts.read(), isEmpty);
  });

  test('the file keeps the newest 200 and survives a reopen; CLEAR empties it', () async {
    final file = File('${work.path}/cap/sync_conflicts.json');
    final log = ConflictLog(file);
    for (var i = 0; i < 205; i++) {
      await log.append(
        SyncConflict(
          at: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          table: 'observations',
          rowId: 'row-$i',
          winner: 'x',
          loser: 'y',
          localVersion: '1',
          incomingVersion: '0',
          kept: true,
        ),
      );
    }
    final list = await log.read();
    expect(list, hasLength(200));
    expect(list.first.rowId, 'row-204', reason: 'newest first');
    expect(list.last.rowId, 'row-5', reason: 'the oldest five fell off');

    final reopened = await ConflictLog(file).read();
    expect(reopened, hasLength(200));
    expect(reopened.first.rowId, 'row-204');

    var ticks = 0;
    final sub = log.changes.listen((_) => ticks++);
    await log.clear();
    expect(await log.read(), isEmpty);
    expect(await ConflictLog(file).read(), isEmpty);
    expect(ticks, 1);
    await sub.cancel();
  });

  test('a damaged file loses its history, not the app', () async {
    final file = File('${work.path}/bad/sync_conflicts.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    final log = ConflictLog(file);
    expect(await log.read(), isEmpty);
    await log.append(
      SyncConflict(
        at: DateTime.utc(2026),
        table: 't',
        rowId: 'r',
        winner: 'x',
        loser: 'y',
        localVersion: '1',
        incomingVersion: '0',
        kept: true,
      ),
    );
    expect(await ConflictLog(file).read(), hasLength(1));
    expect(Diag.entries.any((e) => e.where == 'ConflictLog._load'), isTrue);
  });
}
