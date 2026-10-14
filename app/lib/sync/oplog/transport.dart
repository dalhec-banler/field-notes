part of '../oplog.dart';

const _root = 'sync';

/// Batches carry coordinates and notes. Sealing them is the norm; the
/// clear is a deliberate, spoken exception (D-026, audit finding 11).
void _requireSealedOrAcknowledged(BackupCipher? cipher, bool allowPlaintext) {
  if (cipher != null && cipher.scheme != 'plain') return;
  if (allowPlaintext) return;
  throw StateError(
    'Sync batches would be written in the clear and unauthenticated. '
    'Pass a sealing cipher, or allowPlaintext: true for a local test '
    '(see DECISIONS.md D-026).',
  );
}

mixin _OpLogTransport on _OpLogApply {
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
          jsonEncode({
            'format': OpLog.formatVersion,
            'device': deviceId,
            'ops': ops,
          }),
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
    // Every synced table, resolved once — not a linear scan per op. An op
    // naming anything else (a retired table from an older peer, a table
    // this build has never heard of) finds no entry and is skipped.
    final tables = OpLog.syncedTables(db);
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
        if (format is! int || format > OpLog.formatVersion) {
          throw StateError(
            'Sync batch $file is format $format; this build understands '
            '${OpLog.formatVersion}. Update before syncing.',
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
}
