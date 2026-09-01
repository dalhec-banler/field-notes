import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../backup/target.dart';
import '../db/database.dart';

/// M4a (docs/SYNC-DESIGN.md): the serverless oplog, locally.
///
/// Capture: TEMP triggers on every domain table write a full-row snapshot
/// into `sync_ops` on insert/update, and a tombstone on delete
/// (stamped with the wall clock — the deletion is a NEW event, later than
/// the row's last update, or a peer's equal-timestamp copy would survive). Triggers
/// mean every write path is covered — screens, imports, restores, code
/// that hasn't been written yet — without touching a single call site.
///
/// Order: `seq` (AUTOINCREMENT — sync plumbing, deliberately outside the
/// §4 UUID convention, and never leaves this device as an identity) gives
/// each device a total order over its own ops. Merges never use seq across
/// devices; they use row-level last-writer-wins on the row's own
/// `updated_at` (falling back to deleted/created/recorded timestamps for
/// append-only tables), with the device id as the tiebreak — the LWW-on-HLC
/// rule from the design doc, with the row timestamp as the clock.
///
/// Carry: `push` appends `sync/<device>/<seq range>.json` batches to any
/// [BackupTarget]; `pull` reads every other device's directory in order and
/// applies what it hasn't seen. Both are idempotent; a torn batch is
/// impossible (targets write-then-rename) and a re-read batch is a no-op.
class OpLog {
  OpLog._(this.db, this.deviceId);

  final FieldNotesDb db;
  final String deviceId;

  static const _root = 'sync';

  /// Tables that never sync: the ops themselves and local bookkeeping.
  static const _never = {'sync_ops', 'sync_meta'};

  /// Create the sync tables if needed, remember (or adopt) this device's
  /// id, and install the capture triggers for this connection. Call once
  /// per open database, before the first write that should be captured.
  static Future<OpLog> install(FieldNotesDb db, {String? deviceId}) async {
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS sync_ops (
        seq        INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT NOT NULL,
        row_id     TEXT NOT NULL,
        op         TEXT NOT NULL CHECK (op IN ('put','del')),
        row_ts     TEXT NOT NULL,
        wall       TEXT NOT NULL,
        payload    TEXT
      )''');
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS sync_meta (
        key TEXT PRIMARY KEY, value TEXT NOT NULL
      )''');

    var id = deviceId;
    if (id == null) {
      final row = await db
          .customSelect("SELECT value FROM sync_meta WHERE key = 'device_id'")
          .getSingleOrNull();
      id = row?.data['value'] as String?;
    }
    if (id == null) {
      id = newId();
      await db.customStatement(
        "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('device_id', ?)",
        [id],
      );
    } else {
      await db.customStatement(
        "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('device_id', ?)",
        [id],
      );
    }

    // The apply guard: while a row exists here, triggers stay silent so
    // remote ops don't re-capture as local ones.
    await db.customStatement(
      'CREATE TEMP TABLE IF NOT EXISTS _sync_guard (active INTEGER)',
    );

    final log = OpLog._(db, id);
    await log._installTriggers();
    return log;
  }

  /// The row timestamp expression for LWW, per table shape.
  static String _rowTsExpr(Set<String> cols, String alias) {
    final candidates = [
      if (cols.contains('deleted_at')) '$alias."deleted_at"',
      if (cols.contains('updated_at')) '$alias."updated_at"',
      if (cols.contains('recorded_at')) '$alias."recorded_at"',
      if (cols.contains('created_at')) '$alias."created_at"',
    ];
    if (candidates.isEmpty) {
      return "strftime('%Y-%m-%dT%H:%M:%fZ','now')";
    }
    return 'COALESCE(${candidates.join(', ')})';
  }

  Future<void> _installTriggers() async {
    for (final table in db.allTables) {
      final name = table.actualTableName;
      if (_never.contains(name)) continue;
      final cols = table.columnsByName.keys.toSet();
      if (!cols.contains('id')) continue; // sync rides on TEXT id PKs (§4)
      final jsonPairs = cols.map((c) => "'$c', NEW.\"$c\"").join(', ');
      final guard = '(SELECT COUNT(*) FROM temp._sync_guard) = 0';
      for (final event in ['INSERT', 'UPDATE']) {
        await db.customStatement('''
          CREATE TEMP TRIGGER IF NOT EXISTS _cap_${name}_${event.toLowerCase()}
          AFTER $event ON "$name"
          WHEN $guard
          BEGIN
            INSERT INTO sync_ops (table_name, row_id, op, row_ts, wall, payload)
            VALUES ('$name', NEW."id", 'put', ${_rowTsExpr(cols, 'NEW')},
                    strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                    json_object($jsonPairs));
          END''');
      }
      await db.customStatement('''
        CREATE TEMP TRIGGER IF NOT EXISTS _cap_${name}_delete
        AFTER DELETE ON "$name"
        WHEN $guard
        BEGIN
          INSERT INTO sync_ops (table_name, row_id, op, row_ts, wall, payload)
          VALUES ('$name', OLD."id", 'del',
                  strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                  strftime('%Y-%m-%dT%H:%M:%fZ','now'), NULL);
        END''');
    }
  }

  Future<String?> _meta(String key) async {
    final row = await db
        .customSelect(
          'SELECT value FROM sync_meta WHERE key = ?',
          variables: [Variable.withString(key)],
        )
        .getSingleOrNull();
    return row?.data['value'] as String?;
  }

  Future<void> _setMeta(String key, String value) => db.customStatement(
    'INSERT OR REPLACE INTO sync_meta (key, value) VALUES (?, ?)',
    [key, value],
  );

  /// Ops captured and not yet pushed.
  Future<int> get pendingCount async {
    final last = int.tryParse(await _meta('pushed_seq') ?? '0') ?? 0;
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM sync_ops WHERE seq > ?',
          variables: [Variable.withInt(last)],
        )
        .getSingle();
    return row.data['n'] as int;
  }

  /// Append everything new to `sync/<device>/` on [target]. One batch file
  /// per call; zero ops writes nothing. Returns the number pushed.
  Future<int> push(BackupTarget target) async {
    final last = int.tryParse(await _meta('pushed_seq') ?? '0') ?? 0;
    final rows = await db
        .customSelect(
          'SELECT seq, table_name, row_id, op, row_ts, wall, payload '
          'FROM sync_ops WHERE seq > ? ORDER BY seq',
          variables: [Variable.withInt(last)],
        )
        .get();
    if (rows.isEmpty) return 0;
    final ops = [
      for (final r in rows)
        {
          'seq': r.data['seq'],
          'table': r.data['table_name'],
          'row_id': r.data['row_id'],
          'op': r.data['op'],
          'row_ts': r.data['row_ts'],
          'wall': r.data['wall'],
          'payload': r.data['payload'] == null
              ? null
              : jsonDecode(r.data['payload'] as String),
        },
    ];
    final first = rows.first.data['seq'] as int;
    final lastSeq = rows.last.data['seq'] as int;
    final name =
        '$_root/$deviceId/${first.toString().padLeft(12, '0')}-$lastSeq.json';
    await target.write(
      name,
      Uint8List.fromList(
        utf8.encode(jsonEncode({'format': 1, 'device': deviceId, 'ops': ops})),
      ),
    );
    await _setMeta('pushed_seq', '$lastSeq');
    return rows.length;
  }

  /// Read every other device's batches in order and apply what's new.
  /// Idempotent: cursors advance only after a batch applies, and applying
  /// the same op twice changes nothing (LWW compares equal and moves on).
  Future<SyncPullResult> pull(BackupTarget target) async {
    var applied = 0;
    var skipped = 0;
    final files = await target.list(_root);
    // Group by device dir; process each device's files in name order
    // (zero-padded first-seq makes lexicographic == numeric).
    final byDevice = <String, List<String>>{};
    for (final f in files) {
      final parts = f.split('/');
      if (parts.length < 3 || !f.endsWith('.json')) continue;
      final device = parts[parts.length - 2];
      if (device == deviceId) continue;
      (byDevice[device] ??= []).add(f);
    }
    for (final entry in byDevice.entries) {
      entry.value.sort();
      var cursor = int.tryParse(await _meta('cursor_${entry.key}') ?? '0') ?? 0;
      for (final file in entry.value) {
        final batch = jsonDecode(utf8.decode(await target.read(file))) as Map;
        final ops = (batch['ops'] as List).cast<Map>();
        if (ops.isEmpty) continue;
        if ((ops.last['seq'] as num).toInt() <= cursor) continue;
        for (final op in ops) {
          final seq = (op['seq'] as num).toInt();
          if (seq <= cursor) continue;
          final did = await _apply(op, entry.key);
          did ? applied++ : skipped++;
          cursor = seq;
        }
        await _setMeta('cursor_${entry.key}', '$cursor');
      }
    }
    return SyncPullResult(applied: applied, skipped: skipped);
  }

  /// One op against the local row: last writer wins on the row timestamp,
  /// device id breaks ties. Foreign keys are deferred so a batch can carry
  /// a child one op before its parent.
  Future<bool> _apply(Map op, String fromDevice) async {
    final table = op['table'] as String;
    final rowId = op['row_id'] as String;
    final incomingTs = (op['row_ts'] as String?) ?? '';
    final info = db.allTables
        .where((t) => t.actualTableName == table)
        .cast<TableInfo?>()
        .firstOrNull;
    if (info == null) return false; // schema drift: refuse quietly for now
    final cols = info.columnsByName.keys.toSet();

    var did = false;
    await db.transaction(() async {
      await db.customStatement('PRAGMA defer_foreign_keys = ON');
      await db.customStatement('INSERT INTO _sync_guard VALUES (1)');
      try {
        final local = await db
            .customSelect(
              'SELECT ${_rowTsExpr(cols, '"$table"')} AS ts FROM "$table" '
              'WHERE id = ?',
              variables: [Variable.withString(rowId)],
            )
            .getSingleOrNull();
        final localTs = local?.data['ts'] as String?;
        final localWins =
            localTs != null &&
            (localTs.compareTo(incomingTs) > 0 ||
                (localTs == incomingTs && deviceId.compareTo(fromDevice) > 0));

        if (op['op'] == 'del') {
          if (local != null && !localWins) {
            await db.customStatement('DELETE FROM "$table" WHERE id = ?', [
              rowId,
            ]);
            did = true;
          }
          return;
        }
        final payload = (op['payload'] as Map?)?.cast<String, Object?>();
        if (payload == null) return;
        // Only columns both sides know: an older app applies what it can.
        final use = [
          for (final c in payload.keys)
            if (cols.contains(c)) c,
        ];
        if (use.isEmpty) return;
        if (local == null) {
          final placeholders = List.filled(use.length, '?').join(', ');
          await db.customStatement(
            'INSERT OR REPLACE INTO "$table" '
            '(${use.map((c) => '"$c"').join(', ')}) VALUES ($placeholders)',
            [for (final c in use) payload[c]],
          );
          did = true;
        } else if (!localWins) {
          final sets = use.map((c) => '"$c" = ?').join(', ');
          await db.customStatement('UPDATE "$table" SET $sets WHERE id = ?', [
            for (final c in use) payload[c],
            rowId,
          ]);
          did = true;
        }
      } finally {
        await db.customStatement('DELETE FROM _sync_guard');
      }
    });
    return did;
  }
}

class SyncPullResult {
  const SyncPullResult({required this.applied, required this.skipped});
  final int applied;
  final int skipped;

  @override
  String toString() => 'applied $applied · skipped $skipped';
}
