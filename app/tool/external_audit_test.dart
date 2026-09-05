// Standalone audit reproductions. Run explicitly with:
// flutter test tool/external_audit_test.dart --reporter expanded
// Failing assertions describe the required behavior, not the current bugs.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/backup_engine.dart';
import 'package:field_notes/backup/keyring.dart';
import 'package:field_notes/backup/restore.dart';
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/export/exporter.dart';
import 'package:field_notes/export/map_html.dart';
import 'package:field_notes/export/map_plate.dart';
import 'package:field_notes/export/plate_subject_loader.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const ts = '2026-09-01T12:00:00.000Z';

class HookTarget extends DirectoryTarget {
  HookTarget(super.root);
  Future<void> Function()? afterSnapshot;

  @override
  Future<void> write(String path, Uint8List bytes) async {
    await super.write(path, bytes);
    if (path.startsWith('fieldnotes/db/')) await afterSnapshot?.call();
  }
}

void main() {
  late Directory work;
  late FieldNotesDb db;
  late HookTarget target;
  late BackupKeyring keyring;
  final opened = <FieldNotesDb>[];

  FieldNotesDb memory() {
    final result = FieldNotesDb.forTesting();
    opened.add(result);
    return result;
  }

  FieldNotesDb fromFile(File file) {
    final result = FieldNotesDb.fromFile(file);
    opened.add(result);
    return result;
  }

  Future<Property> property(FieldNotesDb d, String name) async {
    final id = newId();
    await d
        .into(d.properties)
        .insert(
          PropertiesCompanion.insert(
            id: id,
            name: name,
            createdBy: 'local',
            createdAt: ts,
            updatedAt: ts,
          ),
        );
    return (d.select(d.properties)..where((r) => r.id.equals(id))).getSingle();
  }

  Future<String> photo(String propertyId, String content) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    final hash = (await Sha256().hash(bytes)).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final file = File('${work.path}/$hash.jpg')..writeAsBytesSync(bytes);
    await db
        .into(db.media)
        .insert(
          MediaCompanion.insert(
            id: newId(),
            propertyId: propertyId,
            mediaType: 'photo',
            localPath: Value(file.path),
            sha256: Value(hash),
            bytes: Value(bytes.length),
            createdBy: 'local',
            createdAt: ts,
            updatedAt: ts,
          ),
        );
    return hash;
  }

  BackupEngine engine() => BackupEngine(
    db,
    target,
    keyring.cipher,
    envelopeExtra: keyring.envelopeFields,
    secretsProvider: () async => {},
  );

  Future<void> rename(
    FieldNotesDb d,
    String id,
    String name, [
    String at = ts,
  ]) => (d.update(d.properties)..where((r) => r.id.equals(id))).write(
    PropertiesCompanion(name: Value(name), updatedAt: Value(at)),
  );

  Future<String> nameOn(FieldNotesDb d, String id) async => (await (d.select(
    d.properties,
  )..where((r) => r.id.equals(id))).getSingle()).name;

  Future<File> historical(int version, {String condition = 'good'}) async {
    const revisions = {2: '93f7ddf', 3: '9af14f2', 4: '06e0a38', 5: 'f7510dc'};
    final source = await Process.run('git', [
      'show',
      '${revisions[version]}:app/lib/db/schema.drift',
    ]);
    expect(source.exitCode, 0, reason: '${source.stderr}');
    final file = File('${work.path}/v$version.sqlite');
    final old = sqlite.sqlite3.open(file.path);
    try {
      // Remove the single Drift-only Dart field alias from historical DDL.
      old.execute((source.stdout as String).replaceAll(' AS typeKey', ''));
      old.execute('PRAGMA user_version = $version');
      old.execute(
        'INSERT INTO properties (id,name,created_by,created_at,updated_at) '
        'VALUES (?,?,?,?,?)',
        ['prop', 'Place', 'local', ts, ts],
      );
      old.execute(
        'INSERT INTO feature_types (id,"key",label,feature_class,created_at) '
        'VALUES (?,?,?,?,?)',
        ['type', 'gate', 'Gate', 'infrastructure', ts],
      );
      old.execute(
        'INSERT INTO features '
        '(id,property_id,feature_type_id,geojson,lat,lng,created_by,created_at,updated_at) '
        'VALUES (?,?,?,?,?,?,?,?,?)',
        [
          'feature',
          'prop',
          'type',
          '{"type":"Point","coordinates":[-98,31]}',
          31,
          -98,
          'local',
          ts,
          ts,
        ],
      );
      old.execute(
        'INSERT INTO feature_condition_logs '
        '(id,property_id,feature_id,observed_at,condition,created_by,created_at,updated_at) '
        'VALUES (?,?,?,?,?,?,?,?)',
        ['log', 'prop', 'feature', ts, condition, 'local', ts, ts],
      );
    } finally {
      old.close();
    }
    return file;
  }

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    keyring = await BackupKeyring.create(
      'audit fixture only',
      memoryKiB: 256,
      iterations: 1,
    );
  });

  setUp(() {
    work = Directory.systemTemp.createTempSync('field-notes-audit-');
    db = memory();
    target = HookTarget(Directory('${work.path}/store'));
  });

  tearDown(() async {
    for (final d in opened) {
      await d.close();
    }
    opened.clear();
    work.deleteSync(recursive: true);
  });

  for (final version in [2, 3, 4, 5]) {
    test('CONTROL: historical v$version upgrades to v6 and reopens', () async {
      final file = await historical(version);
      final migrated = fromFile(file);
      await migrated.customSelect('SELECT * FROM photo_points').get();
      if (version < 5) {
        expect(
          (await migrated.select(migrated.observations).get()).single.id,
          'feature',
        );
        expect(
          (await migrated.select(migrated.conditionLogs).get()).single.id,
          'log',
        );
      }
      expect(
        await migrated.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
      await migrated.close();
      opened.remove(migrated);
      final reopened = fromFile(file);
      expect(
        (await reopened.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .single,
        6,
      );
    });
  }

  test('M1: retry succeeds after an interrupted v5 migration', () async {
    final file = await historical(4);
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute(
      "CREATE TRIGGER fail_upgrade BEFORE UPDATE ON features "
      "BEGIN SELECT RAISE(ABORT, 'injected interruption'); END",
    );
    raw.close();
    final first = fromFile(file);
    await expectLater(first.select(first.properties).get(), throwsA(anything));
    await first.close();
    opened.remove(first);
    final repair = sqlite.sqlite3.open(file.path);
    repair.execute('DROP TRIGGER fail_upgrade');
    repair.close();
    final retry = fromFile(file);
    // Currently fails with "index idx_condition_obs already exists".
    expect(await retry.select(retry.properties).get(), hasLength(1));
  });

  test('M2: a legal legacy condition does not prevent upgrade', () async {
    final migrated = fromFile(await historical(4, condition: 'dry'));
    expect(await migrated.select(migrated.properties).get(), hasLength(1));
  });

  test('M3: feature attachments follow the migrated observation', () async {
    final file = await historical(4);
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute(
      'INSERT INTO media (id,property_id,media_type,created_by,created_at,updated_at) '
      'VALUES (?,?,?,?,?,?)',
      ['photo', 'prop', 'photo', 'local', ts, ts],
    );
    raw.execute(
      'INSERT INTO media_links (id,property_id,media_id,entity_type,entity_id,created_at) '
      'VALUES (?,?,?,?,?,?)',
      ['link', 'prop', 'photo', 'feature', 'feature', ts],
    );
    raw.close();
    final migrated = fromFile(file);
    final links =
        await (migrated.select(migrated.mediaLinks)..where(
              (l) =>
                  l.entityType.equals('observation') &
                  l.entityId.equals('feature'),
            ))
            .get();
    expect(links, hasLength(1));
  });

  test('B1: encrypted restore rejects substituted ciphertext', () async {
    final p = await property(db, 'Place');
    await photo(p.id, 'first photograph');
    await photo(p.id, 'second photograph');
    final e = engine();
    await e.backup();
    final blobs = (await e.readManifestBody())['blobs'] as List;
    // An untrusted store can swap ciphertext without learning the key.
    await target.write(
      blobs[0]['blob'] as String,
      await target.read(blobs[1]['blob'] as String),
    );
    final pipeline = RestorePipeline(Directory('${work.path}/restored'));
    await expectLater(
      pipeline.stageFromTarget(target, secret: 'audit fixture only'),
      throwsA(anything),
    );
  });

  test('B2: encrypted restore reports a missing inventory blob', () async {
    final p = await property(db, 'Place');
    await photo(p.id, 'only photograph');
    final e = engine();
    await e.backup();
    final blobs = (await e.readManifestBody())['blobs'] as List;
    await target.delete(blobs.single['blob'] as String);
    final pipeline = RestorePipeline(Directory('${work.path}/restored'));
    await expectLater(
      pipeline.stageFromTarget(target, secret: 'audit fixture only'),
      throwsA(anything),
    );
  });

  test('B3: manifest media inventory matches the database snapshot', () async {
    final p = await property(db, 'Place');
    await photo(p.id, 'photograph removed during upload');
    target.afterSnapshot = () async {
      await db
          .update(db.media)
          .write(const MediaCompanion(deletedAt: Value(ts)));
    };
    final e = engine();
    await e.backup();
    final body = await e.readManifestBody();
    final snapshot = File('${work.path}/snapshot.sqlite')
      ..writeAsBytesSync(
        await keyring.cipher.open(await target.read(body['db_path'] as String)),
      );
    final copy = fromFile(snapshot);
    final liveInSnapshot = await (copy.select(
      copy.media,
    )..where((m) => m.deletedAt.isNull())).get();
    expect((body['blobs'] as List).length, liveInSnapshot.length);
  });

  test('S1: restored peer receives a distinct device identity', () async {
    final original = await OpLog.install(db, deviceId: 'phone');
    await property(db, 'Place');
    final e = engine();
    await e.backup();
    final out = File('${work.path}/desk.sqlite');
    await e.restore(
      dbOut: out,
      mediaRestoreDir: Directory('${work.path}/media'),
    );
    final restored = await OpLog.install(fromFile(out));
    expect(restored.deviceId, isNot(original.deviceId));
  });

  test('S2: three devices converge when equal timestamps arrive in different orders', () async {
    final b = memory(), c = memory();
    final aLog = await OpLog.install(db, deviceId: 'a');
    final bLog = await OpLog.install(b, deviceId: 'b');
    final cLog = await OpLog.install(c, deviceId: 'c');
    final p = await property(db, 'seed');
    await aLog.push(target, allowPlaintext: true);
    await bLog.pull(target, allowPlaintext: true);
    await cLog.pull(target, allowPlaintext: true);
    await rename(b, p.id, 'B');
    await rename(c, p.id, 'C');
    await cLog.push(target, allowPlaintext: true);
    await aLog.pull(target, allowPlaintext: true); // A has C's winning row.
    await bLog.push(target, allowPlaintext: true);
    await aLog.pull(
      target,
      allowPlaintext: true,
    ); // Currently mistakes C's row for an A-authored row.
    await bLog.pull(target, allowPlaintext: true);
    await cLog.pull(target, allowPlaintext: true);
    expect(await nameOn(db, p.id), await nameOn(c, p.id));
  });

  test('S3: a delayed old peer cannot resurrect a hard-deleted row', () async {
    final b = memory(), c = memory();
    final aLog = await OpLog.install(db, deviceId: 'a');
    final bLog = await OpLog.install(b, deviceId: 'b');
    final cLog = await OpLog.install(c, deviceId: 'c');
    final p = await property(db, 'seed');
    await aLog.push(target, allowPlaintext: true);
    await bLog.pull(target, allowPlaintext: true);
    await cLog.pull(target, allowPlaintext: true);
    await rename(c, p.id, 'old offline edit');
    await (db.delete(db.properties)..where((r) => r.id.equals(p.id))).go();
    await aLog.push(target, allowPlaintext: true);
    await bLog.pull(target, allowPlaintext: true);
    expect(await b.select(b.properties).get(), isEmpty);
    await cLog.push(target, allowPlaintext: true);
    await bLog.pull(target, allowPlaintext: true);
    expect(await b.select(b.properties).get(), isEmpty);
  });

  test('S4: clock rollback does not leave replicas divergent after sequential edits', () async {
    final b = memory();
    final aLog = await OpLog.install(db, deviceId: 'a');
    final bLog = await OpLog.install(b, deviceId: 'b');
    final p = await property(db, 'before clock correction');
    await aLog.push(target, allowPlaintext: true);
    await bLog.pull(target, allowPlaintext: true);
    await rename(
      db,
      p.id,
      'after clock correction',
      '2026-09-01T11:00:00.000Z',
    );
    await aLog.push(target, allowPlaintext: true);
    await bLog.pull(target, allowPlaintext: true);
    expect(await nameOn(b, p.id), await nameOn(db, p.id));
  });

  test(
    'S4b: mixed timestamp precision preserves chronological ordering',
    () async {
      final b = memory();
      final aLog = await OpLog.install(db, deviceId: 'a');
      final bLog = await OpLog.install(b, deviceId: 'b');
      final p = await property(db, 'earlier millisecond');
      await aLog.push(target, allowPlaintext: true);
      await bLog.pull(target, allowPlaintext: true);
      await rename(
        db,
        p.id,
        'one microsecond later',
        '2026-09-01T12:00:00.000001Z',
      );
      await aLog.push(target, allowPlaintext: true);
      await bLog.pull(target, allowPlaintext: true);
      expect(await nameOn(b, p.id), await nameOn(db, p.id));
    },
  );

  test(
    'S5: sync batches do not expose record contents to the carrier',
    () async {
      final log = await OpLog.install(db, deviceId: 'a');
      await property(db, 'private location audit marker');
      await log.push(target, allowPlaintext: true);
      final file = (await target.list('sync')).single;
      final wire = utf8.decode(await target.read(file), allowMalformed: true);
      expect(wire, isNot(contains('private location audit marker')));
    },
  );

  test(
    'P1: exporting one property does not include another property in SQLite',
    () async {
      final selected = await property(db, 'Public collection site');
      final private = await property(db, 'Private home');
      final dir = await Exporter(db)
          .exportProperty(selected, Directory('${work.path}/export'));
      final copy = fromFile(File('${dir.path}/database.sqlite'));
      final leaked = await (copy.select(
        copy.properties,
      )..where((p) => p.id.equals(private.id))).get();
      expect(leaked, isEmpty);
    },
  );

  test('P2: HTML data cannot terminate its containing script element', () {
    const payload = '</script><script>globalThis.auditMarker = true</script>';
    final html = MapHtml.build(
      PlateSubject(
        propertyName: 'Place',
        zones: [
          PlateZone(
            name: payload,
            geojson: '{"type":"Polygon","coordinates":[[[-98,31],[-97,31],[-97,32],[-98,31]]]}',
          ),
        ],
      ),
    );
    expect(html, isNot(contains(payload)));
  });

  test('D1: unlocated records are excluded from plotted coordinates', () async {
    final p = await property(db, 'Place');
    await db
        .into(db.observations)
        .insert(
          ObservationsCompanion.insert(
            id: newId(),
            propertyId: p.id,
            observedAt: ts,
            localTz: 'UTC',
            lat: 0,
            lng: 0,
            gpsAccuracyM: const Value(-1),
            createdBy: 'local',
            createdAt: ts,
            updatedAt: ts,
          ),
        );
    expect((await loadPlateSubject(db, p)).records, isEmpty);
  });

  test(
    'CONTROL: acreage agrees with a spherical rectangle, holes, and winding',
    () {
      List<List<double>> ring(
        double west,
        double south,
        double east,
        double north,
      ) => [
        [west, south],
        [east, south],
        [east, north],
        [west, north],
        [west, south],
      ];
      double expected(double west, double south, double east, double north) =>
          6378137.0 *
          6378137.0 *
          (east - west) *
          math.pi /
          180 *
          (math.sin(north * math.pi / 180) - math.sin(south * math.pi / 180)) /
          4046.8564224;
      final outer = ring(-98.02, 31.0, -98.0, 31.02);
      final hole = ring(-98.015, 31.005, -98.005, 31.015);
      final want =
          expected(-98.02, 31.0, -98.0, 31.02) -
          expected(-98.015, 31.005, -98.005, 31.015);
      for (final reverse in [false, true]) {
        final rings = [
          outer,
          hole,
        ].map((r) => reverse ? r.reversed.toList() : r).toList();
        expect(
          acresOf(jsonEncode({'type': 'Polygon', 'coordinates': rings})),
          closeTo(want, 0.00001),
        );
        expect(
          acresOf(
            jsonEncode({
              'type': 'MultiPolygon',
              'coordinates': [rings, rings],
            }),
          ),
          closeTo(want * 2, 0.00002),
        );
      }
    },
  );
}
