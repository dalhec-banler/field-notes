part of '../oplog.dart';

mixin _OpLogMeta on _OpLogVersions {
  final _metaTicks = StreamController<void>.broadcast();

  /// Fires whenever the sync bookkeeping (`sync_meta`) is written: a push
  /// mark, a cursor, the last sync time or note. `sync_meta` is not a
  /// drift table, so drift's live streams cannot hear it; this is how the
  /// sync status learns a run finished.
  Stream<void> get metaChanges => _metaTicks.stream;

  /// Local bookkeeping the carrier layer keeps beside the cursors (last
  /// sync time, the last note).
  Future<String?> meta(String key) => _meta(key);
  Future<void> setMeta(String key, String value) => _setMeta(key, value);

  Future<String?> _meta(String key) async {
    final row = await db
        .customSelect(
          'SELECT value FROM sync_meta WHERE key = ?',
          variables: [Variable.withString(key)],
        )
        .getSingleOrNull();
    return row?.data['value'] as String?;
  }

  Future<void> _setMeta(String key, String value) async {
    await db.customStatement(
      'INSERT OR REPLACE INTO sync_meta (key, value) VALUES (?, ?)',
      [key, value],
    );
    if (!_metaTicks.isClosed) _metaTicks.add(null);
  }

  /// Every other device this one has pulled from, in any store.
  Future<Set<String>> peersSeen() async {
    final rows = await db
        .customSelect(
          "SELECT key FROM sync_meta WHERE key LIKE 'cursor_%' "
          "OR key LIKE 'store:%:cursor_%'",
        )
        .get();
    final peers = <String>{};
    for (final r in rows) {
      final key = r.data['key'] as String;
      final i = key.lastIndexOf('cursor_');
      if (i < 0) continue;
      final peer = key.substring(i + 'cursor_'.length);
      if (peer.isNotEmpty && peer != deviceId) peers.add(peer);
    }
    return peers;
  }
}
