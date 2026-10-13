// Live-database guard.
//
// Opens a COPY of a real Field Notes database read-only and checks that the
// row counts match a recorded baseline. Nothing in this test writes. It runs
// only when both defines are given, so the normal suite is unaffected:
//
//   flutter test test/live_db_guard_test.dart \
//     --dart-define=FN_LIVE_DB=/path/to/copy.sqlite \
//     --dart-define=FN_LIVE_COUNTS=/path/to/counts.json
//
// The baseline JSON maps table name to row count (see tool/live_db_counts.sh).
// Tables that exist in the database but not in the baseline are reported, not
// failed, so a new table never masks a lost row in an old one.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

const _dbPath = String.fromEnvironment('FN_LIVE_DB');
const _countsPath = String.fromEnvironment('FN_LIVE_COUNTS');

void main() {
  final enabled = _dbPath.isNotEmpty && _countsPath.isNotEmpty;

  test('live database row counts match the recorded baseline', () {
    final baseline = (jsonDecode(File(_countsPath).readAsStringSync()) as Map)
        .map((k, v) => MapEntry(k as String, v as int));

    final db = sqlite3.open(_dbPath, mode: OpenMode.readOnly);
    try {
      final integrity = db.select('PRAGMA integrity_check').first.values.first;
      expect(integrity, 'ok', reason: 'integrity_check on $_dbPath');

      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type='table' "
              "AND name NOT LIKE 'sqlite_%' ORDER BY name")
          .map((r) => r['name'] as String)
          .toList();

      final mismatches = <String>[];
      final unlisted = <String>[];
      for (final t in tables) {
        final n = db.select('SELECT COUNT(*) AS n FROM "$t"').first['n'] as int;
        if (!baseline.containsKey(t)) {
          unlisted.add('$t=$n');
          continue;
        }
        if (baseline[t] != n) mismatches.add('$t: baseline ${baseline[t]}, now $n');
      }
      final missing = baseline.keys.where((t) => !tables.contains(t)).toList();

      if (unlisted.isNotEmpty) {
        // ignore: avoid_print
        print('tables not in baseline (add them to counts.json): $unlisted');
      }
      expect(missing, isEmpty, reason: 'tables in baseline but gone from db');
      expect(mismatches, isEmpty, reason: 'row counts changed:\n${mismatches.join('\n')}');
    } finally {
      db.dispose();
    }
  }, skip: enabled ? false : 'set FN_LIVE_DB and FN_LIVE_COUNTS to run');
}
