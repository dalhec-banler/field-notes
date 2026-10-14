part of '../oplog.dart';

// ── capture ──────────────────────────────────────────────────────

/// The row timestamp kept for diagnostics. It is NOT the merge rule any
/// more (D-026); `sync_versions.version` is.
String _rowTsExpr(Set<String> cols, String alias) {
  final candidates = [
    if (cols.contains('deleted_at')) '$alias."deleted_at"',
    if (cols.contains('updated_at')) '$alias."updated_at"',
    if (cols.contains('recorded_at')) '$alias."recorded_at"',
    if (cols.contains('created_at')) '$alias."created_at"',
  ];
  if (candidates.isEmpty) {
    return "strftime('%Y-%m-%dT%H:%M:%fZ','now')";
  }
  // SQLite's COALESCE wants two arguments or more. A table with a single
  // timestamp column (feature_types has only created_at) got
  // `COALESCE(NEW."created_at")`, and every INSERT into it failed with
  // "wrong number of arguments" the moment the triggers were in place —
  // which on a fresh install is before the feature types are seeded
  // (smoke suite, 2026-10-13).
  if (candidates.length == 1) return candidates.single;
  return 'COALESCE(${candidates.join(', ')})';
}

mixin _OpLogTriggers on _OpLogMeta {
  Future<void> _installTriggers() async {
    // ~3 triggers × ~30 tables: one transaction, not ~100 autocommits on
    // the startup path.
    await db.transaction(() async {
      for (final table in OpLog.syncedTables(db).values) {
        final name = table.actualTableName;
        final cols = table.columnsByName.keys.toSet();
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
}
