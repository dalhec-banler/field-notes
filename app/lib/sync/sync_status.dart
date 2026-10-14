import 'dart:async';

import '../db/database.dart';
import 'oplog.dart';

/// Where sync stands, as one person can read it (D-038 item 12): when it
/// last worked, when it last tried, what went wrong if it did, how much of
/// this device's work is still waiting, what the last run brought in, and
/// who it has heard from. Derived from `sync_meta` and `sync_ops`, never
/// stored as a thing of its own.
class SyncStatus {
  const SyncStatus({
    this.lastSuccessAt,
    this.lastAttemptAt,
    this.lastFailure,
    this.lastFailureAt,
    this.pending = 0,
    this.receivedLastRun = 0,
    this.peers = const {},
  });

  /// `last_sync_at` — a run that exchanged with at least one store.
  final DateTime? lastSuccessAt;

  /// `last_sync_attempt` — every run, including the ones that got nowhere.
  final DateTime? lastAttemptAt;

  /// `last_sync_failure` — the sentence from the most recent run that
  /// failed, kept until a later run succeeds in full. Names the cause.
  final String? lastFailure;
  final DateTime? lastFailureAt;

  /// Ops captured here and not yet pushed to the app folder.
  final int pending;

  /// Ops applied from peers by the most recent run (`last_sync_received`).
  final int receivedLastRun;

  /// Device ids this one has pulled from.
  final Set<String> peers;

  /// True when the most recent attempt is the one that failed.
  bool get lastAttemptFailed {
    final f = lastFailureAt;
    if (f == null) return false;
    final s = lastSuccessAt;
    return s == null || !s.isAfter(f);
  }

  /// Read once.
  static Future<SyncStatus> read(OpLog log) async {
    DateTime? when(String? iso) => DateTime.tryParse(iso ?? '')?.toUtc();
    final failure = await log.meta('last_sync_failure');
    return SyncStatus(
      lastSuccessAt: when(await log.meta('last_sync_at')),
      lastAttemptAt: when(await log.meta('last_sync_attempt')),
      lastFailure: failure == null || failure.isEmpty ? null : failure,
      lastFailureAt: when(await log.meta('last_sync_failure_at')),
      pending: await log.pendingCount,
      receivedLastRun:
          int.tryParse(await log.meta('last_sync_received') ?? '') ?? 0,
      peers: await log.peersSeen(),
    );
  }

  /// Emits once on listen and again whenever it may have changed: any
  /// write to a synced table (a new op is waiting) and any write to the
  /// sync bookkeeping (a run moved a mark or a cursor). Bursts collapse
  /// into one recomputation; the latest state is always the last emitted.
  static Stream<SyncStatus> watch(FieldNotesDb db, OpLog log) {
    late StreamController<SyncStatus> out;
    StreamSubscription<void>? tables;
    StreamSubscription<void>? meta;
    var computing = false;
    var dirty = false;

    Future<void> recompute() async {
      if (computing) {
        dirty = true;
        return;
      }
      computing = true;
      try {
        do {
          dirty = false;
          final s = await read(log);
          if (!out.isClosed) out.add(s);
        } while (dirty && !out.isClosed);
      } catch (e, st) {
        if (!out.isClosed) out.addError(e, st);
      } finally {
        computing = false;
      }
    }

    out = StreamController<SyncStatus>(
      onListen: () {
        // db.changes() fires once on listen, which is the first read.
        tables = db.changes(db.allTables.toSet()).listen((_) => recompute());
        meta = log.metaChanges.listen((_) => recompute());
      },
      onCancel: () async {
        await tables?.cancel();
        await meta?.cancel();
      },
    );
    return out.stream;
  }

  /// "Last synced 2 h ago · 3 changes waiting · last problem: needs the
  /// passphrase (yesterday)". Plain, and the problem names its cause.
  String line({DateTime? now}) {
    final t = now ?? DateTime.now().toUtc();
    final bits = <String>[
      lastSuccessAt == null
          ? 'Never synced'
          : 'Last synced ${ago(lastSuccessAt!, now: t)}',
      pending == 0
          ? 'nothing waiting'
          : '$pending change${pending == 1 ? '' : 's'} waiting',
      if (lastFailure != null)
        'last problem: ${_trimSentence(lastFailure!)}'
            '${lastFailureAt == null ? '' : ' (${ago(lastFailureAt!, now: t)})'}',
    ];
    return bits.join(' · ');
  }

  static String _trimSentence(String s) {
    var t = s.trim();
    while (t.endsWith('.')) {
      t = t.substring(0, t.length - 1);
    }
    return t;
  }

  /// "just now", "4 min ago", "2 h ago", "yesterday", "5 d ago".
  static String ago(DateTime then, {DateTime? now}) {
    final d = (now ?? DateTime.now().toUtc()).difference(then.toUtc());
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    if (d.inDays < 2) return 'yesterday';
    return '${d.inDays} d ago';
  }
}
