import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// D-038, the rule: no new `CHECK (col IN (...))` constraints. SQLite
/// cannot loosen a CHECK, so adding one value to a list has twice (v4,
/// v10) meant rebuilding a table in a migration. A new set of kinds is a
/// small lookup table or a text column validated in Dart.
///
/// This is a read-only parse of schema.drift. The number can only go
/// DOWN — when a table is rebuilt for some other reason and its CHECKs
/// come off — and when it does, lower the pin here in the same commit.
///
/// D-038 wrote "thirty-nine"; the file holds thirty-seven of this shape
/// (the thirty-eighth CHECK, on plant_checkins, is an `OR`, not an `IN`).
void main() {
  test('schema.drift has no new CHECK (... IN (...)) constraint', () {
    final file = File('lib/db/schema.drift');
    expect(file.existsSync(), isTrue, reason: 'run from app/');
    final sql = file
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('--'))
        .map((l) => l.replaceFirst(RegExp(r'--.*$'), ''))
        .join('\n');
    final enumChecks = RegExp(
      r'CHECK\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\s+IN\s*\(',
      caseSensitive: false,
    ).allMatches(sql).length;
    const pinned = 37;
    expect(
      enumChecks,
      lessThanOrEqualTo(pinned),
      reason:
          'A new CHECK (col IN (...)) appeared in schema.drift. D-038 forbids '
          'it: use a lookup table or validate in Dart.',
    );
    expect(
      enumChecks,
      pinned,
      reason:
          'The count moved ($enumChecks vs $pinned). If CHECKs came off in a '
          'rebuild, lower `pinned` here in the same commit.',
    );
  });
}
