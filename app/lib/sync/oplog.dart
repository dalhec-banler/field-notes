import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../backup/backup_crypto.dart';
import '../backup/target.dart';
import '../db/database.dart';

/// M4a (docs/SYNC-DESIGN.md): the serverless oplog.
///
/// Capture: TEMP triggers on every domain table write a full-row snapshot
/// into `sync_ops` on insert/update, and a tombstone on delete. Triggers
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

class OpLog {
  OpLog._(this.db, this.deviceId);

  final FieldNotesDb db;
  final String deviceId;

  static const _root = 'sync';

  /// The wire format this build writes and accepts.
  static const formatVersion = 2;

  /// Tables that never sync: the ops themselves and local bookkeeping.
  static const _never = {
    'sync_ops',
    'sync_meta',
    'sync_versions',
    'sync_clock',
  };

  /// Columns that describe THIS device's disk, not the record: a photo's
  /// path on the phone means nothing on the desk. They are captured (the
  /// trigger snapshots the row) but never applied; the receiving device
  /// fetches the blob and files it where it likes.
  static const _deviceLocal = {
    'media': {'local_path', 'thumb_path', 'remote_path', 'upload_state'},
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
  static Future<OpLog> install(
    FieldNotesDb db, {
    String? deviceId,
    File? identityFile,
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

    final log = OpLog._(db, id);
    await log._installTriggers();
    return log;
  }

  // ── the logical clock ────────────────────────────────────────────

  /// Fixed width so text order IS chronological order, whatever the
  /// precision of anybody's timestamps.
  static String _stamp(int phys, int ctr) =>
      '${phys.toString().padLeft(15, '0')}-${ctr.toString().padLeft(6, '0')}';

  static int _physOf(String version) =>
      int.tryParse(version.split('-').first) ?? 0;

  static int _ctrOf(String version) {
    final parts = version.split('-');
    return parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  }

  Future<(int, int)> _readClock() async {
    final row = await db
        .customSelect('SELECT phys, ctr FROM sync_clock WHERE id = 0')
        .getSingleOrNull();
    if (row == null) return (0, 0);
    return (row.data['phys'] as int, row.data['ctr'] as int);
  }

  Future<void> _writeClock(int phys, int ctr) => db.customStatement(
    'INSERT OR REPLACE INTO sync_clock (id, phys, ctr) VALUES (0, ?, ?)',
    [phys, ctr],
  );

  /// The next version this device may stamp. Never goes backwards, even
  /// if the operating system's clock does.
  Future<String> _nextVersion() async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final (phys, ctr) = await _readClock();
    final nextPhys = now > phys ? now : phys;
    final nextCtr = now > phys ? 0 : ctr + 1;
    await _writeClock(nextPhys, nextCtr);
    return _stamp(nextPhys, nextCtr);
  }

  /// Learn from a version seen from a peer, so anything this device
  /// stamps afterwards sorts after it.
  Future<void> _observe(String version) async {
    final rPhys = _physOf(version);
    final rCtr = _ctrOf(version);
    final (phys, ctr) = await _readClock();
    if (rPhys > phys || (rPhys == phys && rCtr > ctr)) {
      await _writeClock(rPhys, rCtr);
    }
  }

  // ── capture ──────────────────────────────────────────────────────

  /// The row timestamp kept for diagnostics. It is NOT the merge rule any
  /// more (D-026); `sync_versions.version` is.
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
    // ~3 triggers × ~30 tables: one transaction, not ~100 autocommits on
    // the startup path.
    await db.transaction(() async {
      for (final table in db.allTables) {
        final name = table.actualTableName;
        if (_never.contains(name)) continue;
        final cols = table.columnsByName.keys.toSet();
        if (!cols.contains('id')) continue; // sync rides on TEXT id PKs (§4)
        final jsonPairs = cols.map((c) => "'$c', NEW.\"$c\"").join(', ');
        final guard = '(SELECT COUNT(*) FROM temp._sync_guard) = 0';
        // The version is stamped WHEN THE WRITE HAPPENS, not when it is
        // pushed. An edit made offline on Tuesday must sort before a
        // deletion made on Wednesday even if it reaches the folder on
        // Thursday — stamping at push time let a stale edit outrank the
        // deletion that should have buried it (D-026, audit finding 8).
        const nowMs =
            "CAST((julianday('now') - 2440587.5) * 86400000.0 AS INTEGER)";
        const tick =
            'UPDATE sync_clock SET '
            'ctr = CASE WHEN $nowMs > phys THEN 0 ELSE ctr + 1 END, '
            'phys = MAX(phys, $nowMs) WHERE id = 0;';
        const stamp =
            "(SELECT printf('%015d-%06d', phys, ctr) "
            'FROM sync_clock WHERE id = 0)';
        const who = "(SELECT value FROM sync_meta WHERE key = 'device_id')";
        for (final event in ['INSERT', 'UPDATE']) {
          await db.customStatement('''
          CREATE TEMP TRIGGER IF NOT EXISTS _cap_${name}_${event.toLowerCase()}
          AFTER $event ON "$name"
          WHEN $guard
          BEGIN
            $tick
            INSERT INTO sync_ops (table_name, row_id, op, row_ts, wall,
                                  payload, version)
            VALUES ('$name', NEW."id", 'put', ${_rowTsExpr(cols, 'NEW')},
                    strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                    json_object($jsonPairs), $stamp);
            INSERT OR REPLACE INTO sync_versions
              (table_name, row_id, version, device, deleted)
            VALUES ('$name', NEW."id", $stamp, $who, 0);
          END''');
        }
        // A deletion notes which property the row belonged to, so a
        // property-scoped store (D-030) can carry it; nothing else of the
        // row survives.
        final delPayload = cols.contains('property_id')
            ? "json_object('property_id', OLD.\"property_id\")"
            : 'NULL';
        await db.customStatement('''
        CREATE TEMP TRIGGER IF NOT EXISTS _cap_${name}_delete
        AFTER DELETE ON "$name"
        WHEN $guard
        BEGIN
          $tick
          INSERT INTO sync_ops (table_name, row_id, op, row_ts, wall,
                                payload, version)
          VALUES ('$name', OLD."id", 'del',
                  strftime('%Y-%m-%dT%H:%M:%fZ','now'),
                  strftime('%Y-%m-%dT%H:%M:%fZ','now'), $delPayload, $stamp);
          INSERT OR REPLACE INTO sync_versions
            (table_name, row_id, version, device, deleted)
          VALUES ('$name', OLD."id", $stamp, $who, 1);
        END''');
      }
    });
  }

  /// Stamp any op captured before this build, which has no version of its
  /// own. New writes are stamped by the trigger at the moment they happen;
  /// this only settles the backlog.
  Future<void> _settle() async {
    final rows = await db
        .customSelect(
          'SELECT seq, table_name, row_id, op FROM sync_ops '
          'WHERE version IS NULL ORDER BY seq',
        )
        .get();
    if (rows.isEmpty) return;
    for (final r in rows) {
      final version = await _nextVersion();
      await db.customStatement(
        'UPDATE sync_ops SET version = ? WHERE seq = ?',
        [version, r.data['seq'] as int],
      );
      await _recordVersion(
        r.data['table_name'] as String,
        r.data['row_id'] as String,
        version,
        deviceId,
        deleted: r.data['op'] == 'del',
      );
    }
  }

  Future<void> _recordVersion(
    String table,
    String rowId,
    String version,
    String device, {
    required bool deleted,
  }) => db.customStatement(
    'INSERT OR REPLACE INTO sync_versions '
    '(table_name, row_id, version, device, deleted) VALUES (?, ?, ?, ?, ?)',
    [table, rowId, version, device, deleted ? 1 : 0],
  );

  /// What this device believes about a row: the winning version, who wrote
  /// it, and whether it is a tombstone.
  Future<({String version, String device, bool deleted})?> _versionOf(
    String table,
    String rowId,
  ) async {
    final row = await db
        .customSelect(
          'SELECT version, device, deleted FROM sync_versions '
          'WHERE table_name = ? AND row_id = ?',
          variables: [Variable.withString(table), Variable.withString(rowId)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return (
      version: row.data['version'] as String,
      device: row.data['device'] as String,
      deleted: (row.data['deleted'] as int) != 0,
    );
  }

  /// Local bookkeeping the carrier layer keeps beside the cursors (last
  /// sync time, the last note).
  Future<String?> meta(String key) => _meta(key);
  Future<void> setMeta(String key, String value) => _setMeta(key, value);

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

  /// Batches carry coordinates and notes. Sealing them is the norm; the
  /// clear is a deliberate, spoken exception (D-026, audit finding 11).
  static void _requireSealedOrAcknowledged(
    BackupCipher? cipher,
    bool allowPlaintext,
  ) {
    if (cipher != null && cipher.scheme != 'plain') return;
    if (allowPlaintext) return;
    throw StateError(
      'Sync batches would be written in the clear and unauthenticated. '
      'Pass a sealing cipher, or allowPlaintext: true for a local test '
      '(see DECISIONS.md D-026).',
    );
  }

  /// Append what's new to `sync/<device>/` on [target]: one batch file per
  /// call, at most [maxOps] ops (a phone's first push carries its whole
  /// history — the carrier loops until [pendingCount] is zero rather than
  /// writing one file the size of the journal). Zero ops writes nothing.
  /// Returns the number pushed.
  Future<int> push(
    BackupTarget target, {
    BackupCipher? cipher,
    bool allowPlaintext = false,
    int maxOps = 500,
    SyncScope scope = const SyncScope.all(),
  }) async {
    _requireSealedOrAcknowledged(cipher, allowPlaintext);
    await _settle();
    final mark = scope.metaKey('pushed_seq');
    var last = int.tryParse(await _meta(mark) ?? '0') ?? 0;
    // A property store skips the ops that are not its own; the mark moves
    // past them so they are never scanned twice, and the scan keeps going
    // until a batch is written or the log runs out.
    while (true) {
      final rows = await db
          .customSelect(
            'SELECT seq, table_name, row_id, op, row_ts, wall, payload, version '
            'FROM sync_ops WHERE seq > ? ORDER BY seq LIMIT ?',
            variables: [Variable.withInt(last), Variable.withInt(maxOps)],
          )
          .get();
      if (rows.isEmpty) return 0;
      final ops = <Map<String, Object?>>[];
      for (final r in rows) {
        final payload = r.data['payload'] == null
            ? null
            : (jsonDecode(r.data['payload'] as String) as Map)
                  .cast<String, Object?>();
        if (!scope.includes(
          r.data['table_name'] as String,
          r.data['row_id'] as String,
          payload,
        )) {
          continue;
        }
        ops.add({
          'seq': r.data['seq'],
          'table': r.data['table_name'],
          'row_id': r.data['row_id'],
          'op': r.data['op'],
          'version': r.data['version'],
          'row_ts': r.data['row_ts'],
          'wall': r.data['wall'],
          'payload': payload,
        });
      }
      final lastSeq = rows.last.data['seq'] as int;
      if (ops.isEmpty) {
        await _setMeta(mark, '$lastSeq');
        last = lastSeq;
        continue;
      }
      final first = ops.first['seq'] as int;
      final ext = cipher?.ext ?? '';
      final name =
          '$_root/$deviceId/${first.toString().padLeft(12, '0')}-$lastSeq.json$ext';
      final body = Uint8List.fromList(
        utf8.encode(
          jsonEncode({'format': formatVersion, 'device': deviceId, 'ops': ops}),
        ),
      );
      await target.write(name, await (cipher ?? PlainCipher()).seal(body));
      await _setMeta(mark, '$lastSeq');
      return ops.length;
    }
  }

  /// Read every other device's batches in order and apply what's new.
  /// Idempotent: cursors advance only after a batch applies, and applying
  /// the same op twice changes nothing (the version compares equal).
  Future<SyncPullResult> pull(
    BackupTarget target, {
    BackupCipher? cipher,
    bool allowPlaintext = false,
    SyncScope scope = const SyncScope.all(),
  }) async {
    _requireSealedOrAcknowledged(cipher, allowPlaintext);
    await _settle();
    var applied = 0;
    var skipped = 0;
    // Rows land here by raw SQL, which drift's live streams never hear
    // about — the desk's species panel kept a phone edit's old shape until
    // a relaunch (2026-09-08). Every table written is announced at the end.
    final touched = <String>{};
    final files = await target.list(_root);
    // Group by device dir; process each device's files in name order
    // (zero-padded first-seq makes lexicographic == numeric).
    final byDevice = <String, List<String>>{};
    for (final f in files) {
      final parts = f.split('/');
      if (parts.length < 3 || !f.contains('.json')) continue;
      final device = parts[parts.length - 2];
      if (device == deviceId) continue;
      (byDevice[device] ??= []).add(f);
    }
    // Every synced table, resolved once — not a linear scan per op.
    final tables = {for (final t in db.allTables) t.actualTableName: t};
    for (final entry in byDevice.entries) {
      entry.value.sort();
      final cursorKey = scope.metaKey('cursor_${entry.key}');
      var cursor = int.tryParse(await _meta(cursorKey) ?? '0') ?? 0;
      for (final file in entry.value) {
        // The name carries the batch's seq range: a fully-applied batch is
        // skipped without being downloaded.
        final range = RegExp(r'-(\d+)\.json').firstMatch(file);
        if (range != null && int.parse(range.group(1)!) <= cursor) continue;
        final raw = await target.read(file);
        final Map batch;
        try {
          batch = jsonDecode(
            utf8.decode(await (cipher ?? PlainCipher()).open(raw)),
          ) as Map;
        } catch (e) {
          throw StateError(
            'Could not open sync batch $file. It is not readable with this '
            "key, or it is not this app's format: $e",
          );
        }
        // A batch is only what its own directory claims to be.
        final claimed = '${batch['device']}';
        if (claimed != entry.key) {
          throw StateError(
            'Sync batch $file claims device "$claimed" but sits in '
            '"${entry.key}". Refusing it.',
          );
        }
        final format = batch['format'];
        if (format is! int || format > formatVersion) {
          throw StateError(
            'Sync batch $file is format $format; this build understands '
            '$formatVersion. Update before syncing.',
          );
        }
        final ops = (batch['ops'] as List).cast<Map>();
        if (ops.isEmpty) continue;
        if ((ops.last['seq'] as num).toInt() <= cursor) continue;
        // One transaction per batch file: one commit, the guard and the
        // deferred-FK pragma set once — not one fsync per op.
        await db.transaction(() async {
          await db.customStatement('PRAGMA defer_foreign_keys = ON');
          await db.customStatement('INSERT INTO _sync_guard VALUES (1)');
          try {
            for (final op in ops) {
              final seq = (op['seq'] as num).toInt();
              if (seq <= cursor) continue;
              // A property store applies only what belongs to the
              // property: a batch that carries anything else — another
              // property's rows, a deletion it cannot place — is a peer
              // that is confused or hostile, and those ops are skipped.
              if (!scope.includes(
                op['table'] as String,
                op['row_id'] as String,
                (op['payload'] as Map?)?.cast<String, Object?>(),
              )) {
                skipped++;
                cursor = seq;
                continue;
              }
              final did = await _apply(op, entry.key, tables);
              did ? applied++ : skipped++;
              if (did) touched.add(op['table'] as String);
              cursor = seq;
            }
          } finally {
            await db.customStatement('DELETE FROM _sync_guard');
          }
        });
        await _setMeta(cursorKey, '$cursor');
      }
    }
    if (touched.isNotEmpty) {
      db.notifyUpdates({for (final t in touched) TableUpdate(t)});
    }
    return SyncPullResult(applied: applied, skipped: skipped);
  }

  /// One op against the local row. The winner is the higher logical
  /// version; an exact tie is broken by comparing the two WRITERS — the
  /// device that wrote the version we hold against the device that wrote
  /// the one arriving — so every replica reaches the same answer whatever
  /// order the batches turn up in.
  Future<bool> _apply(
    Map op,
    String fromDevice,
    Map<String, TableInfo> tables,
  ) async {
    final table = op['table'] as String;
    final rowId = op['row_id'] as String;
    final incoming = (op['version'] as String?) ?? '';
    if (incoming.isEmpty) return false; // pre-D-026 batch: refuse quietly
    await _observe(incoming);

    final info = tables[table];
    if (info == null) return false; // schema drift: refuse quietly for now
    final cols = info.columnsByName.keys.toSet();

    var local = await _versionOf(table, rowId);
    if (local == null) {
      // A row that predates versioning (arrived by restore, say). Give it
      // a version derived from its own timestamp so the comparison is
      // still meaningful, and record it.
      final existing = await db
          .customSelect(
            'SELECT ${_rowTsExpr(cols, '"$table"')} AS ts FROM "$table" '
            'WHERE id = ?',
            variables: [Variable.withString(rowId)],
          )
          .getSingleOrNull();
      if (existing != null) {
        final ts = existing.data['ts'] as String?;
        final ms = DateTime.tryParse(ts ?? '')?.millisecondsSinceEpoch ?? 0;
        local = (version: _stamp(ms, 0), device: '', deleted: false);
      }
    }

    final incomingIsDelete = op['op'] == 'del';
    if (local != null) {
      final cmp = local.version.compareTo(incoming);
      final bool localWins;
      if (cmp != 0) {
        localWins = cmp > 0;
      } else if (local.deleted != incomingIsDelete) {
        // Same version, one of them a deletion: THE DELETION WINS. Two
        // devices acting in the same millisecond is common (and certain in
        // tests), and letting a higher device id resurrect a row somebody
        // deleted is the wrong way to break that tie. Every replica
        // decides this identically from data it holds, so they converge.
        localWins = local.deleted;
      } else {
        localWins = local.device.compareTo(fromDevice) > 0;
      }
      if (localWins) return false;
    }

    if (incomingIsDelete) {
      await db.customStatement('DELETE FROM "$table" WHERE id = ?', [rowId]);
      // The tombstone keeps its version: a peer that was away when this
      // happened must not resurrect the row with an older edit.
      await _recordVersion(table, rowId, incoming, fromDevice, deleted: true);
      return true;
    }

    final payload = (op['payload'] as Map?)?.cast<String, Object?>();
    if (payload == null) return false;
    // Only columns both sides know: an older app applies what it can.
    // Never a column that describes the writer's disk.
    final deviceLocal = _deviceLocal[table] ?? const <String>{};
    final use = [
      for (final c in payload.keys)
        if (cols.contains(c) && !deviceLocal.contains(c)) c,
    ];
    if (use.isEmpty) return false;
    final present =
        (await db
            .customSelect(
              'SELECT 1 AS n FROM "$table" WHERE id = ?',
              variables: [Variable.withString(rowId)],
            )
            .getSingleOrNull()) !=
        null;
    if (present) {
      final sets = use.map((c) => '"$c" = ?').join(', ');
      await db.customStatement('UPDATE "$table" SET $sets WHERE id = ?', [
        for (final c in use) payload[c],
        rowId,
      ]);
    } else {
      final placeholders = List.filled(use.length, '?').join(', ');
      await db.customStatement(
        'INSERT OR REPLACE INTO "$table" '
        '(${use.map((c) => '"$c"').join(', ')}) VALUES ($placeholders)',
        [for (final c in use) payload[c]],
      );
    }
    await _recordVersion(table, rowId, incoming, fromDevice, deleted: false);
    return true;
  }
}

class SyncPullResult {
  const SyncPullResult({required this.applied, required this.skipped});
  final int applied;
  final int skipped;

  @override
  String toString() => 'applied $applied · skipped $skipped';
}
