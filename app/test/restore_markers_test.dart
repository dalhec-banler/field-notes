import 'dart:io';

import 'package:field_notes/backup/restore.dart';
import 'package:field_notes/db/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The two-marker contract: READY is consumed by the DB swap, so a crash or
/// error during media remap can never re-apply the snapshot on a later
/// launch and wipe records written since.
void main() {
  late Directory docs;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('restore_markers');
  });

  tearDown(() {
    docs.deleteSync(recursive: true);
  });

  Future<void> stageFakeDb() async {
    final staging = Directory(p.join(docs.path, 'restore_staged'))
      ..createSync(recursive: true);
    final staged = FieldNotesDb.fromFile(File(p.join(staging.path, 'db.sqlite')));
    await staged.customSelect('SELECT 1').get(); // force open + schema
    await staged.close();
    File(p.join(staging.path, 'READY')).writeAsStringSync('now');
  }

  test('apply consumes READY, sets APPLIED, and never applies twice',
      () async {
    await stageFakeDb();
    final pipeline = RestorePipeline(docs);
    final liveDb = p.join(docs.path, 'field_notes.sqlite');

    // A live DB with a hot journal, like a killed session leaves behind.
    File(liveDb).writeAsStringSync('old live db');
    File('$liveDb-journal').writeAsStringSync('hot journal');

    expect(pipeline.hasStagedRestore, isTrue);
    expect(pipeline.applyStagedDb(liveDb), isTrue);

    expect(pipeline.hasStagedRestore, isFalse, reason: 'READY consumed');
    expect(pipeline.hasPendingMediaRemap, isTrue, reason: 'APPLIED set');
    expect(File('$liveDb-journal').existsSync(), isFalse,
        reason: 'sidecar moved aside with the old DB');
    expect(
        docs
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).contains('pre-restore'))
            .length,
        2,
        reason: 'old DB and its journal both preserved');

    // Second launch before remap finished: must NOT touch the DB again.
    File(liveDb).writeAsStringSync('records written since restore');
    expect(pipeline.applyStagedDb(liveDb), isFalse);
    expect(File(liveDb).readAsStringSync(), 'records written since restore');
  });

  test('remap with nothing to place cleans staging', () async {
    await stageFakeDb();
    final pipeline = RestorePipeline(docs);
    final liveDb = p.join(docs.path, 'field_notes.sqlite');
    pipeline.applyStagedDb(liveDb);

    final db = FieldNotesDb.fromFile(File(liveDb));
    final n = await pipeline.remapRestoredMedia(db);
    await db.close();
    expect(n, 0);
    expect(pipeline.hasPendingMediaRemap, isFalse);
    expect(Directory(p.join(docs.path, 'restore_staged')).existsSync(),
        isFalse);
  });
}
