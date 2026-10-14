import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:field_notes/sync/sync_status.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-038 item 12: the status a person reads is derived from `sync_meta`
/// and `sync_ops`, says when sync last worked and last tried, names the
/// last problem, and counts what is waiting — and it is live.
void main() {
  late FieldNotesDb db;
  late OpLog log;

  Future<String> seedProperty() async {
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: id,
            name: 'Place',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<void> addObservation(String propId) async {
    final now = nowUtcIso();
    await db
        .into(db.observations)
        .insert(
          ObservationsCompanion.insert(
            id: newId(),
            propertyId: propId,
            observedAt: now,
            localTz: 'America/Chicago',
            lat: 31.06,
            lng: -98.05,
            notes: const Value('x'),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  setUp(() async {
    db = FieldNotesDb.forTesting();
    log = await OpLog.install(db, deviceId: 'desk');
  });

  tearDown(() => db.close());

  test('nothing yet reads as never synced, nothing waiting', () async {
    final s = await SyncStatus.read(log);
    expect(s.lastSuccessAt, isNull);
    expect(s.lastAttemptAt, isNull);
    expect(s.lastFailure, isNull);
    expect(s.lastAttemptFailed, isFalse);
    expect(s.pending, 0);
    expect(s.peers, isEmpty);
    expect(s.line(), 'Never synced · nothing waiting');
  });

  test('derived from the fixture meta and the unpushed tail of the log', () async {
    final now = DateTime.utc(2026, 10, 13, 12, 0);
    final propId = await seedProperty(); // op 1
    await addObservation(propId); // op 2
    await log.setMeta('pushed_seq', '2');
    await addObservation(propId); // op 3
    await addObservation(propId); // op 4
    await addObservation(propId); // op 5 — three waiting
    await log.setMeta(
      'last_sync_at',
      now.subtract(const Duration(hours: 2)).toIso8601String(),
    );
    await log.setMeta('last_sync_attempt', now.toIso8601String());
    await log.setMeta(
      'last_sync_failure',
      'Sync needs the backup passphrase once — open Sync.',
    );
    await log.setMeta(
      'last_sync_failure_at',
      now.subtract(const Duration(hours: 30)).toIso8601String(),
    );
    await log.setMeta('last_sync_received', '4');
    await log.setMeta('cursor_phone', '17');
    await log.setMeta('store:property:abc:cursor_tablet', '3');
    await log.setMeta('cursor_desk', '9'); // our own id never counts

    final s = await SyncStatus.read(log);
    expect(s.pending, 3);
    expect(s.receivedLastRun, 4);
    expect(s.peers, {'phone', 'tablet'});
    expect(s.lastSuccessAt, now.subtract(const Duration(hours: 2)));
    expect(s.lastAttemptAt, now);
    expect(s.lastFailure, 'Sync needs the backup passphrase once — open Sync.');
    expect(
      s.lastAttemptFailed,
      isFalse,
      reason: 'the failure is older than the last success',
    );
    expect(
      s.line(now: now),
      'Last synced 2 h ago · 3 changes waiting · '
      'last problem: Sync needs the backup passphrase once — open Sync '
      '(yesterday)',
    );
  });

  test('a failure after the last success marks the last attempt failed', () async {
    final now = DateTime.utc(2026, 10, 13, 12, 0);
    await log.setMeta(
      'last_sync_at',
      now.subtract(const Duration(days: 3)).toIso8601String(),
    );
    await log.setMeta('last_sync_attempt', now.toIso8601String());
    await log.setMeta(
      'last_sync_failure',
      'Could not reach Drive — no network, or Google did not answer.',
    );
    await log.setMeta('last_sync_failure_at', now.toIso8601String());
    final s = await SyncStatus.read(log);
    expect(s.lastAttemptFailed, isTrue);
    expect(
      s.line(now: now),
      'Last synced 3 d ago · nothing waiting · last problem: Could not '
      'reach Drive — no network, or Google did not answer (just now)',
    );
  });

  test('an empty failure key reads as no failure', () async {
    await log.setMeta('last_sync_failure', '');
    final s = await SyncStatus.read(log);
    expect(s.lastFailure, isNull);
  });

  test('ago reads the way a person says it', () {
    final now = DateTime.utc(2026, 10, 13, 12, 0);
    String at(Duration d) => SyncStatus.ago(now.subtract(d), now: now);
    expect(at(const Duration(seconds: 20)), 'just now');
    expect(at(const Duration(minutes: 5)), '5 min ago');
    expect(at(const Duration(hours: 3)), '3 h ago');
    expect(at(const Duration(hours: 30)), 'yesterday');
    expect(at(const Duration(days: 6)), '6 d ago');
  });

  test('watch emits on listen, on a captured write, and on a sync mark', () async {
    final seen = <SyncStatus>[];
    final sub = SyncStatus.watch(db, log).listen(seen.add);
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 120));
    await settle();
    expect(seen, hasLength(1));
    expect(seen.last.pending, 0);

    final propId = await seedProperty();
    await settle();
    expect(seen.last.pending, 1, reason: 'a write is a waiting change');

    await addObservation(propId);
    await settle();
    expect(seen.last.pending, 2);

    // A push mark is sync_meta, which no drift stream hears; the op log
    // announces it itself.
    await log.setMeta('pushed_seq', '2');
    await log.setMeta('last_sync_at', nowUtcIso());
    await settle();
    expect(seen.last.pending, 0);
    expect(seen.last.lastSuccessAt, isNotNull);
    await sub.cancel();
  });
}
