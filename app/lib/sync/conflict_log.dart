import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../services/diag.dart';

/// One place where two devices disagreed about a row and the merge rule
/// picked a side (D-038 item 12). The losing version is not kept here —
/// the op log still has it — only the fact, so a person can see that an
/// edit of theirs was overruled, or that an edit from elsewhere was.
class SyncConflict {
  const SyncConflict({
    required this.at,
    required this.table,
    required this.rowId,
    required this.winner,
    required this.loser,
    required this.localVersion,
    required this.incomingVersion,
    required this.kept,
    this.fields = const [],
  });

  /// UTC, when this device noticed.
  final DateTime at;
  final String table;
  final String rowId;

  /// Device ids. [winner] wrote the version that stands.
  final String winner;
  final String loser;

  /// The logical versions compared (`phys-ctr`, see OpLog).
  final String localVersion;
  final String incomingVersion;

  /// True when the local row stood and the arriving op was refused; false
  /// when the arriving op overwrote a local change nobody had seen yet.
  final bool kept;

  /// Column names whose values differed, when that was cheap to find.
  final List<String> fields;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'table': table,
    'row_id': rowId,
    'winner': winner,
    'loser': loser,
    'local_version': localVersion,
    'incoming_version': incomingVersion,
    'kept': kept,
    'fields': fields,
  };

  static SyncConflict fromJson(Map<String, Object?> m) => SyncConflict(
    at: DateTime.tryParse('${m['at']}')?.toUtc() ?? DateTime.utc(1970),
    table: '${m['table']}',
    rowId: '${m['row_id']}',
    winner: '${m['winner'] ?? ''}',
    loser: '${m['loser'] ?? ''}',
    localVersion: '${m['local_version'] ?? ''}',
    incomingVersion: '${m['incoming_version'] ?? ''}',
    kept: m['kept'] == true,
    fields: [for (final f in (m['fields'] as List?) ?? const []) '$f'],
  );

  /// One line for the diagnostics log.
  String describe() {
    final what = fields.isEmpty ? '' : ' (${fields.join(', ')})';
    return kept
        ? '$table $rowId: kept $winner\'s version $localVersion over '
              '$loser\'s $incomingVersion$what'
        : '$table $rowId: $winner\'s version $incomingVersion overwrote '
              '$loser\'s unsent $localVersion$what';
  }
}

/// A capped record of conflicts in `sync_conflicts.json` beside the
/// database: the newest [cap] entries, oldest dropped. No table, no schema
/// change (D-038). With no file it keeps the same list in memory only.
///
/// Reads and writes are serialised through one chain so two conflicts in
/// the same pull cannot interleave their rewrites of the file.
class ConflictLog {
  ConflictLog(this.file, {this.cap = 200});

  final File? file;
  final int cap;

  List<SyncConflict>? _cache;
  Future<void> _tail = Future.value();
  final _changes = StreamController<void>.broadcast();

  /// Fires after every append and clear.
  Stream<void> get changes => _changes.stream;

  /// Newest first.
  Future<List<SyncConflict>> read() async {
    await _tail;
    return List.unmodifiable((await _load()).reversed);
  }

  Future<void> append(SyncConflict c) {
    Diag.log(c.describe(), where: 'ConflictLog');
    _tail = _tail.then((_) async {
      final list = await _load();
      list.add(c);
      while (list.length > cap) {
        list.removeAt(0);
      }
      await _save(list);
      _changes.add(null);
    });
    return _tail;
  }

  Future<void> clear() {
    _tail = _tail.then((_) async {
      await _save([]);
      _changes.add(null);
    });
    return _tail;
  }

  /// Oldest first, as stored.
  Future<List<SyncConflict>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final f = file;
    var list = <SyncConflict>[];
    if (f != null && f.existsSync()) {
      try {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is List) {
          list = [
            for (final e in raw)
              if (e is Map) SyncConflict.fromJson(e.cast<String, Object?>()),
          ];
        }
      } catch (e, st) {
        // A damaged file loses its history, not the app; say so.
        Diag.report(e, st, where: 'ConflictLog._load');
        list = [];
      }
    }
    return _cache = list;
  }

  Future<void> _save(List<SyncConflict> list) async {
    _cache = list;
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      await f.writeAsString(
        jsonEncode([for (final c in list) c.toJson()]),
        flush: true,
      );
    } catch (e, st) {
      // The memory copy still has it for this session.
      Diag.report(e, st, where: 'ConflictLog._save');
    }
  }
}
