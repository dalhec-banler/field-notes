import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import '../backup/backup_crypto.dart';
import '../backup/target.dart';
import '../db/database.dart';
import '../db/retired_tables.dart';
import 'conflict_log.dart';

part 'oplog/core.dart';
part 'oplog/clock.dart';
part 'oplog/versions.dart';
part 'oplog/meta.dart';
part 'oplog/triggers.dart';
part 'oplog/apply.dart';
part 'oplog/transport.dart';

/// M4a (docs/SYNC-DESIGN.md): the serverless oplog.
///
/// Capture: TEMP triggers on every domain table ([syncedTables]) write a
/// full-row snapshot into `sync_ops` on insert/update, and a tombstone on
/// delete. Triggers
/// mean every write path is covered — screens, imports, restores, code
/// that hasn't been written yet — without touching a single call site.
///
/// Merge (rewritten 2026-09-04 for D-026, after an external audit): the
/// wall clock is no longer the version. Every captured op is stamped with
/// a HYBRID LOGICAL CLOCK — physical milliseconds that never go backwards,
/// a counter for ties, and the writing device — and the winning version of
/// every row is remembered in `sync_versions`, deletions included.
///
/// That fixes four things a wall clock got wrong:
///
///  * A corrected clock used to lose the edit made after the correction;
///    the logical clock only moves forward, including past what it has
///    seen from peers.
///  * ISO strings of different precision compared wrongly as text
///    (`…000Z` looked later than `…000001Z`). Versions are fixed width.
///  * The equal-version tiebreak compared the RECEIVING device with the
///    incoming writer, so three peers could settle on different rows and
///    stay that way. It now compares the writer of the version actually
///    stored.
///  * Applying a delete dropped the row and its version together, so a
///    peer that was offline during the deletion could resurrect the row
///    with a stale edit. Tombstones keep their version.
///
/// Carry: `push` appends `sync/<device>/<seq range>.json` batches to any
/// [BackupTarget]; `pull` reads every other device's directory in order
/// and applies what it hasn't seen. Both are idempotent. Batches are
/// SEALED when given a cipher; writing them in the clear takes an
/// explicit acknowledgement, because they carry coordinates and notes.
/// What a store carries (D-030). The device-pair app folder carries
/// everything; a shared property folder carries one property — its rows,
/// the species and feature-type library, and nothing that says where the
/// owner's other land is. Cursors and the pushed mark are kept per store,
/// so one device can exchange with several folders.
class SyncScope {
  const SyncScope.all() : propertyId = null;
  const SyncScope.property(String this.propertyId);

  final String? propertyId;

  bool get isAll => propertyId == null;

  /// Tables without a property of their own that every store may carry,
  /// for rows whose `property_id` is NULL (the seeded library).
  static const library = {'taxa', 'feature_types'};

  /// The `sync_meta` key for [name] in this store. The app folder keeps
  /// the unprefixed names D-028 wrote.
  String metaKey(String name) =>
      isAll ? name : 'store:property:$propertyId:$name';

  /// Whether an op belongs in this store. A deletion recorded before the
  /// trigger learned to note the property cannot be placed, and stays out
  /// of a property store: a shared folder must never carry a row it
  /// cannot vouch for, in either direction.
  bool includes(String table, String rowId, Map<String, Object?>? payload) {
    if (isAll) return true;
    if (table == 'properties') return rowId == propertyId;
    final owner = payload?['property_id'];
    if (owner != null) return owner == propertyId;
    if (library.contains(table) && payload != null) return true;
    return false;
  }
}

class OpLog
    with
        _OpLogCore,
        _OpLogClock,
        _OpLogVersions,
        _OpLogMeta,
        _OpLogTriggers,
        _OpLogApply,
        _OpLogTransport {
  OpLog._(this.db, this.deviceId, this.conflicts);

  @override
  final FieldNotesDb db;
  @override
  final String deviceId;

  /// Where the merge rule's overrulings are noted (D-038 item 12).
  @override
  final ConflictLog conflicts;

  /// The wire format this build writes and accepts.
  static const formatVersion = 2;

  /// Tables that never sync: the ops themselves and local bookkeeping.
  static const _never = {
    'sync_ops',
    'sync_meta',
    'sync_versions',
    'sync_clock',
  };

  /// The tables the oplog captures and applies: every table drift knows
  /// that rides on a TEXT `id` primary key (§4), less the sync bookkeeping
  /// and the retired tables nothing writes (D-038 item 9). One place decides
  /// this for both the triggers and the pull, so a table cannot be captured
  /// on one device and refused on another.
  static Map<String, TableInfo> syncedTables(GeneratedDatabase db) => {
    for (final t in db.allTables)
      if (!_never.contains(t.actualTableName) &&
          !kRetiredTables.contains(t.actualTableName) &&
          t.columnsByName.containsKey('id'))
        t.actualTableName: t,
  };

  /// Create the sync tables if needed, remember (or adopt) this device's
  /// id, and install the capture triggers for this connection. Call once
  /// per open database, before the first write that should be captured.
  ///
  /// [identityFile] holds this INSTALLATION's device id, deliberately
  /// outside the journal. It used to live only in `sync_meta`, which
  /// travels inside a backup: restoring the phone onto the desk cloned the
  /// phone's identity, and two devices then wrote the same batch names and
  /// skipped each other's work as their own. A database that arrives from
  /// somewhere else gets a new identity and a clean slate of cursors,
  /// because this installation has pushed nothing.
  ///
  /// [conflictFile] is `sync_conflicts.json` beside the database; left
  /// null, conflicts are kept for the session only (tests).
  static Future<OpLog> install(
    FieldNotesDb db, {
    String? deviceId,
    File? identityFile,
    File? conflictFile,
  }) async {
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
    // The merge version of every row this device knows about, including
    // rows it has deleted (D-026).
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS sync_versions (
        table_name TEXT NOT NULL,
        row_id     TEXT NOT NULL,
        version    TEXT NOT NULL,
        device     TEXT NOT NULL,
        deleted    INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (table_name, row_id)
      )''');
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS sync_clock (
        id INTEGER PRIMARY KEY CHECK (id = 0),
        phys INTEGER NOT NULL,
        ctr  INTEGER NOT NULL
      )''');
    await db.customStatement(
      'INSERT OR IGNORE INTO sync_clock (id, phys, ctr) VALUES (0, 0, 0)',
    );
    // `version` arrives on sync_ops for databases created before D-026.
    try {
      await db.customStatement('ALTER TABLE sync_ops ADD COLUMN version TEXT');
    } catch (e) {
      if (!'$e'.toLowerCase().contains('duplicate column')) rethrow;
    }

    final carried =
        (await db
                    .customSelect(
                      "SELECT value FROM sync_meta WHERE key = 'device_id'",
                    )
                    .getSingleOrNull())
                ?.data['value']
            as String?;
    var id = deviceId;
    if (id == null && identityFile != null && identityFile.existsSync()) {
      final held = identityFile.readAsStringSync().trim();
      if (held.isNotEmpty) id = held;
    }
    id ??= newId();
    // Whether this installation is brand new or has had an identity for
    // months: a journal that carries somebody else's device id arrived by
    // restore, and its exchange history is theirs.
    if (carried != null && carried != id) {
      // This journal was written by another installation. Its cursors and
      // push position describe that device's exchange history, not ours,
      // and every op in it is that device's to push. Start our cursor for
      // it at what the copy already holds.
      await db.customStatement(
        "DELETE FROM sync_meta WHERE key = 'pushed_seq' OR key LIKE 'cursor_%'",
      );
      final top = await db
          .customSelect('SELECT COALESCE(MAX(seq), 0) AS n FROM sync_ops')
          .getSingle();
      final n = top.data['n'] as int;
      if (n > 0) {
        await db.customStatement(
          'INSERT OR REPLACE INTO sync_meta (key, value) VALUES (?, ?)',
          ['cursor_$carried', '$n'],
        );
      }
      await db.customStatement('DELETE FROM sync_ops');
    }
    if (identityFile != null && !identityFile.existsSync()) {
      identityFile.parent.createSync(recursive: true);
      identityFile.writeAsStringSync(id);
    }
    await db.customStatement(
      "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('device_id', ?)",
      [id],
    );

    // A device that has never pushed owns only the ops for rows it wrote
    // (sync_versions says who wrote every row). Anything else in its
    // journal arrived by restore and belongs to the writer, who pushes
    // its own — pushing it from here would re-author the phone's whole
    // history as this desk's (D-028). Drop those, and start this device's
    // cursor for that writer at what the copy already holds, so the first
    // pull doesn't re-apply a history this database was born with. Keyed
    // on "never pushed", not on the identity change, so a desk adopted
    // before this rule existed heals itself on its next launch.
    final pushed = await db
        .customSelect("SELECT value FROM sync_meta WHERE key = 'pushed_seq'")
        .getSingleOrNull();
    if (pushed == null) {
      final foreign = await db
          .customSelect(
            'SELECT v.device AS device, MAX(o.seq) AS top, COUNT(*) AS n '
            'FROM sync_ops o JOIN sync_versions v '
            'ON v.table_name = o.table_name AND v.row_id = o.row_id '
            'WHERE v.device != ? GROUP BY v.device',
            variables: [Variable.withString(id)],
          )
          .get();
      for (final r in foreign) {
        final device = r.data['device'] as String;
        if (device.isEmpty) continue;
        await db.customStatement(
          'INSERT OR REPLACE INTO sync_meta (key, value) VALUES (?, ?)',
          ['cursor_$device', '${r.data['top']}'],
        );
      }
      if (foreign.isNotEmpty) {
        await db.customStatement(
          'DELETE FROM sync_ops WHERE seq IN ('
          'SELECT o.seq FROM sync_ops o JOIN sync_versions v '
          'ON v.table_name = o.table_name AND v.row_id = o.row_id '
          'WHERE v.device != ?)',
          [id],
        );
      }
      // Ops captured before D-026 carry no version and name no writer.
      // A device that has never pushed has nothing to lose by shedding
      // them: a peer bootstraps from a restore, never from this backlog,
      // and pushing a stale full-row snapshot of every old record helps
      // no one (on the desk it was the phone's history, re-authored).
      await db.customStatement('DELETE FROM sync_ops WHERE version IS NULL');
    }

    // The apply guard: while a row exists here, triggers stay silent so
    // remote ops don't re-capture as local ones.
    await db.customStatement(
      'CREATE TEMP TABLE IF NOT EXISTS _sync_guard (active INTEGER)',
    );

    final log = OpLog._(db, id, ConflictLog(conflictFile));
    await log._installTriggers();
    return log;
  }

  /// Run [body] with capture switched off: for writes that are this
  /// device's own business — filing a fetched blob under a local path —
  /// and must not be pushed to anyone.
  Future<T> quietly<T>(Future<T> Function() body) async {
    await db.customStatement('INSERT INTO _sync_guard VALUES (1)');
    try {
      return await body();
    } finally {
      await db.customStatement('DELETE FROM _sync_guard');
    }
  }

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
}

class SyncPullResult {
  const SyncPullResult({required this.applied, required this.skipped});
  final int applied;
  final int skipped;

  @override
  String toString() => 'applied $applied · skipped $skipped';
}
