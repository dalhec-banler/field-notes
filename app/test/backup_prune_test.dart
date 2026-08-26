import 'dart:io';

import 'package:field_notes/backup/backup_crypto.dart';
import 'package:field_notes/backup/backup_engine.dart';
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:flutter_test/flutter_test.dart';

/// Spec §11.7: keep the last 5 DB generations; blobs are never pruned by the
/// backup process.
void main() {
  late FieldNotesDb db;
  late Directory store;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    store = Directory.systemTemp.createTempSync('prune');
    final now = nowUtcIso();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
          id: newId(),
          name: 'Yard',
          createdBy: 'a',
          createdAt: now,
          updatedAt: now,
        ));
  });

  tearDown(() async {
    await db.close();
    store.deleteSync(recursive: true);
  });

  test('only the newest five generations survive', () async {
    final engine =
        BackupEngine(db, DirectoryTarget(store), const PlainCipher());
    for (var i = 0; i < 8; i++) {
      await engine.backup();
    }
    final dumps = Directory('${store.path}/fieldnotes/db')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(dumps.length, BackupEngine.generationsToKeep);
    expect(dumps.first, startsWith('4.'), reason: 'gens 1-3 pruned');
    expect(dumps.last, startsWith('8.'));
    // The manifest still points at the newest.
    final manifest = File('${store.path}/fieldnotes/manifest.json');
    expect(manifest.readAsStringSync(), contains('"generation":8'));
  });
}
