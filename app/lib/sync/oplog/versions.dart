part of '../oplog.dart';

mixin _OpLogVersions on _OpLogClock {
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

  /// The highest op seq any store has been given: the app folder's
  /// `pushed_seq` and every shared property's. Zero when nothing has ever
  /// been pushed anywhere.
  Future<int> _highestPushedMark() async {
    final rows = await db
        .customSelect(
          "SELECT value FROM sync_meta WHERE key = 'pushed_seq' "
          "OR key LIKE 'store:%:pushed_seq'",
        )
        .get();
    var top = 0;
    for (final r in rows) {
      final n = int.tryParse(r.data['value'] as String) ?? 0;
      if (n > top) top = n;
    }
    return top;
  }

  /// Whether any peer may already know about this row: one of its ops is
  /// at or below a push mark, or it has no ops of this device's at all
  /// (it arrived by pull or by restore, so the writer has it). A row that
  /// is only in the unpushed tail of the journal is still private to this
  /// device — and the one case where a hard erase is still honest.
  Future<bool> hasBeenPushed(String table, String rowId) async {
    final row = await db
        .customSelect(
          'SELECT MIN(seq) AS lo, COUNT(*) AS n FROM sync_ops '
          'WHERE table_name = ? AND row_id = ?',
          variables: [Variable.withString(table), Variable.withString(rowId)],
        )
        .getSingle();
    if ((row.data['n'] as int) == 0) return true;
    return (row.data['lo'] as int) <= await _highestPushedMark();
  }

  /// Whether this device has changed the row since anything was last
  /// pushed: its newest op is above every push mark.
  Future<bool> _hasUnpushedChange(String table, String rowId) async {
    final row = await db
        .customSelect(
          'SELECT MAX(seq) AS hi FROM sync_ops '
          'WHERE table_name = ? AND row_id = ?',
          variables: [Variable.withString(table), Variable.withString(rowId)],
        )
        .getSingle();
    final hi = row.data['hi'] as int?;
    if (hi == null) return false;
    return hi > await _highestPushedMark();
  }

  /// After a hard erase of rows nobody has been told about: drop their ops
  /// and versions, so the next push carries nothing of them — not the
  /// insert, not the delete. A row any store has already seen is left
  /// alone; its deletion must travel as the tombstone the trigger wrote.
  Future<void> forgetUnpushed(
    Iterable<(String table, String rowId)> rows,
  ) async {
    for (final (table, rowId) in rows) {
      if (await hasBeenPushed(table, rowId)) continue;
      await db.customStatement(
        'DELETE FROM sync_ops WHERE table_name = ? AND row_id = ?',
        [table, rowId],
      );
      await db.customStatement(
        'DELETE FROM sync_versions WHERE table_name = ? AND row_id = ?',
        [table, rowId],
      );
    }
  }
}
