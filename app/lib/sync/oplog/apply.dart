part of '../oplog.dart';

/// Columns that describe THIS device's disk, not the record: a photo's
/// path on the phone means nothing on the desk. They are captured (the
/// trigger snapshots the row) but never applied; the receiving device
/// fetches the blob and files it where it likes.
const _deviceLocal = {
  'media': {'local_path', 'thumb_path', 'remote_path', 'upload_state'},
};

mixin _OpLogApply on _OpLogTriggers {
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
    // Not a table this build syncs — retired (D-038 item 9), unknown, or
    // bookkeeping. Refused, counted as skipped, cursor still advances.
    if (info == null) return false;
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
      // Two writers disagreed and the rule picked one (D-038 item 12). The
      // same device's own op arriving again — a second store, a re-read
      // batch — compares equal and is not a disagreement.
      final crossWriter = local.device != fromDevice;
      if (localWins) {
        if (crossWriter) {
          await _noteConflict(
            table,
            rowId,
            cols,
            op,
            local: local,
            fromDevice: fromDevice,
            kept: true,
          );
        }
        return false;
      }
      // The arriving version wins over an edit made HERE that no store has
      // been given yet: the other side cannot have seen it, so this is a
      // real cross-over, not a later edit landing after an earlier one.
      if (crossWriter &&
          local.device == deviceId &&
          await _hasUnpushedChange(table, rowId)) {
        await _noteConflict(
          table,
          rowId,
          cols,
          op,
          local: local,
          fromDevice: fromDevice,
          kept: false,
        );
      }
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

  /// Record one overruling. The columns that differed are found with one
  /// read of the local row when both sides are writes; a deletion on
  /// either side names no columns.
  Future<void> _noteConflict(
    String table,
    String rowId,
    Set<String> cols,
    Map op, {
    required ({String version, String device, bool deleted}) local,
    required String fromDevice,
    required bool kept,
  }) async {
    final incoming = (op['version'] as String?) ?? '';
    final payload = (op['payload'] as Map?)?.cast<String, Object?>();
    final fields = <String>[];
    if (payload != null && op['op'] != 'del' && !local.deleted) {
      final deviceLocal = _deviceLocal[table] ?? const <String>{};
      final row = await db
          .customSelect(
            'SELECT * FROM "$table" WHERE id = ?',
            variables: [Variable.withString(rowId)],
          )
          .getSingleOrNull();
      if (row != null) {
        for (final c in payload.keys) {
          if (!cols.contains(c) || deviceLocal.contains(c)) continue;
          if ('${row.data[c]}' != '${payload[c]}') fields.add(c);
        }
      }
    }
    await conflicts.append(
      SyncConflict(
        at: DateTime.now().toUtc(),
        table: table,
        rowId: rowId,
        winner: kept ? local.device : fromDevice,
        loser: kept ? fromDevice : local.device,
        localVersion: local.version,
        incomingVersion: incoming,
        kept: kept,
        fields: fields,
      ),
    );
  }
}
