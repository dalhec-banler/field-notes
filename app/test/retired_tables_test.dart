import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/retired_tables.dart';
import 'package:field_notes/export/exporter.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;

/// D-038 item 9 (docs/SCHEMA-RESERVED.md): the tables nothing writes stay
/// in the schema, untouched, and out of every code path. These tests hold
/// the line in both directions — a retired table must get no trigger and
/// no export, and every OTHER id-PK table must keep both.
void main() {
  const syncBookkeeping = {
    'sync_ops',
    'sync_meta',
    'sync_versions',
    'sync_clock',
  };

  test('the retired set is the six D-038 names and every one is still in the schema', () async {
    final db = FieldNotesDb.forTesting();
    addTearDown(db.close);
    expect(kRetiredTables, {
      'profiles',
      'memberships',
      'invites',
      'devices',
      'deployments',
      'detections',
    });
    // Retired, not dropped: drift still knows each one, and the file still
    // has it. A DROP is a migration (D-038).
    final known = {for (final t in db.allTables) t.actualTableName};
    for (final t in kRetiredTables) {
      expect(known, contains(t), reason: '$t must stay in schema.drift');
    }
  });

  group('oplog', () {
    late FieldNotesDb db;
    late OpLog log;
    setUp(() async {
      db = FieldNotesDb.forTesting();
      log = await OpLog.install(db, deviceId: 'device-a');
    });
    tearDown(() => db.close());

    Future<Set<String>> triggeredTables() async {
      final rows = await db
          .customSelect(
            "SELECT tbl_name FROM sqlite_temp_master WHERE type = 'trigger' "
            "AND name LIKE '_cap_%'",
          )
          .get();
      return {for (final r in rows) r.data['tbl_name'] as String};
    }

    test('no capture trigger on a retired table', () async {
      final triggered = await triggeredTables();
      for (final t in kRetiredTables) {
        expect(triggered, isNot(contains(t)), reason: '$t has a trigger');
      }
    });

    test('every other id-PK table still has all three triggers', () async {
      final rows = await db
          .customSelect(
            "SELECT tbl_name, name FROM sqlite_temp_master "
            "WHERE type = 'trigger' AND name LIKE '_cap_%'",
          )
          .get();
      final byTable = <String, Set<String>>{};
      for (final r in rows) {
        (byTable[r.data['tbl_name'] as String] ??= {}).add(
          r.data['name'] as String,
        );
      }
      final expected = <String>{};
      for (final t in db.allTables) {
        final name = t.actualTableName;
        if (syncBookkeeping.contains(name)) continue;
        if (kRetiredTables.contains(name)) continue;
        if (!t.columnsByName.containsKey('id')) continue;
        expected.add(name);
        expect(byTable[name], {
          '_cap_${name}_insert',
          '_cap_${name}_update',
          '_cap_${name}_delete',
        }, reason: '$name lost a capture trigger');
      }
      expect(expected, isNotEmpty);
      expect(expected, contains('observations'));
      expect(expected, contains('tracks'));
      expect(expected, contains('feature_types'));
      expect(OpLog.syncedTables(db).keys.toSet(), expected);
    });

    test('a write to a retired table is not journalled', () async {
      final now = nowUtcIso();
      await db
          .into(db.profiles)
          .insert(
            ProfilesCompanion.insert(
              id: newId(),
              displayName: 'nobody',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final n = await db
          .customSelect(
            "SELECT COUNT(*) AS n FROM sync_ops WHERE table_name = 'profiles'",
          )
          .getSingle();
      expect(n.data['n'], 0);
    });

    test('a pulled op naming a retired table is skipped, not applied, not an error', () async {
      final work = Directory.systemTemp.createTempSync('retired');
      addTearDown(() => work.deleteSync(recursive: true));
      final store = DirectoryTarget(work);
      final now = nowUtcIso();
      final ops = [
        {
          'seq': 1,
          'table': 'profiles',
          'row_id': 'p-1',
          'op': 'put',
          'version': '000001700000000-000000',
          'row_ts': now,
          'wall': now,
          'payload': {
            'id': 'p-1',
            'display_name': 'ghost',
            'created_at': now,
            'updated_at': now,
          },
        },
        {
          'seq': 2,
          'table': 'detections',
          'row_id': 'd-1',
          'op': 'del',
          'version': '000001700000000-000001',
          'row_ts': now,
          'wall': now,
          'payload': {'property_id': 'x'},
        },
        {
          'seq': 3,
          'table': 'no_such_table',
          'row_id': 'z-1',
          'op': 'put',
          'version': '000001700000000-000002',
          'row_ts': now,
          'wall': now,
          'payload': {'id': 'z-1'},
        },
      ];
      final body = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': OpLog.formatVersion,
            'device': 'device-b',
            'ops': ops,
          }),
        ),
      );
      await store.write('sync/device-b/000000000001-3.json', body);

      final res = await log.pull(store, allowPlaintext: true);
      expect(res.applied, 0);
      expect(res.skipped, 3);
      final profiles = await db.select(db.profiles).get();
      expect(profiles, isEmpty, reason: 'the retired row was not written');
      // The cursor moved past the batch: pulling again does nothing new.
      final again = await log.pull(store, allowPlaintext: true);
      expect(again.applied, 0);
      expect(again.skipped, 0);
    });
  });

  group('exporter', () {
    test('the CSV list names no retired table, and the SQLite copy keeps every other table', () async {
      final db = FieldNotesDb.forTesting();
      addTearDown(db.close);
      for (final t in Exporter.csvTables) {
        expect(kRetiredTables, isNot(contains(t)));
        expect(Exporter.keepsInDatabase(t), isTrue);
      }
      for (final t in db.allTables) {
        final name = t.actualTableName;
        final keep =
            !syncBookkeeping.contains(name) && !kRetiredTables.contains(name);
        expect(
          Exporter.keepsInDatabase(name),
          keep,
          reason:
              '$name ${keep ? 'holds user data and must be kept' : 'must be handed over empty'}',
        );
      }
    });

    test('an export carries every non-retired table\'s rows and empties the retired ones', () async {
      final db = FieldNotesDb.forTesting();
      addTearDown(db.close);
      final tmp = Directory.systemTemp.createTempSync('retired-export');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final now = nowUtcIso();
      final propId = newId();
      await db
          .into(db.properties)
          .insert(
            PropertiesCompanion.insert(
              id: propId,
              name: 'Place',
              createdBy: 'austin',
              createdAt: now,
              updatedAt: now,
            ),
          );
      await db
          .into(db.observations)
          .insert(
            ObservationsCompanion.insert(
              id: newId(),
              propertyId: propId,
              observedAt: now,
              localTz: 'CDT',
              lat: 31.0,
              lng: -98.0,
              createdBy: 'austin',
              createdAt: now,
              updatedAt: now,
            ),
          );
      // A stray row in a retired table (nothing in the app writes one; this
      // is the raw insert a test can make) does not travel.
      await db
          .into(db.profiles)
          .insert(
            ProfilesCompanion.insert(
              id: newId(),
              displayName: 'stray',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final property = await (db.select(
        db.properties,
      )..where((x) => x.id.equals(propId))).getSingle();

      final dir = await Exporter(db).exportProperty(property, tmp);
      expect(
        File(p.join(dir.path, 'data', 'detections.csv')).existsSync(),
        isFalse,
      );
      for (final t in Exporter.csvTables) {
        expect(
          File(p.join(dir.path, 'data', '$t.csv')).existsSync(),
          isTrue,
          reason: '$t.csv',
        );
      }

      final copy = raw.sqlite3.open(
        p.join(dir.path, 'database.sqlite'),
        mode: raw.OpenMode.readOnly,
      );
      addTearDown(copy.close);
      final present = {
        for (final r in copy.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%'",
        ))
          r['name'] as String,
      };
      int count(String t) =>
          copy.select('SELECT COUNT(*) AS n FROM "$t"').first['n'] as int;
      for (final t in db.allTables) {
        final name = t.actualTableName;
        expect(
          present,
          contains(name),
          reason: '$name table missing from copy',
        );
        if (kRetiredTables.contains(name)) {
          expect(count(name), 0, reason: '$name should be empty in the export');
        }
      }
      expect(count('observations'), 1);
      expect(count('properties'), 1);
      // The source database was not touched.
      expect((await db.select(db.profiles).get()).length, 1);
    });
  });
}
