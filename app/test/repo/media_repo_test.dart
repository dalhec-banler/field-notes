import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/repo/media_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixture.dart';

void main() {
  late FieldNotesDb db;
  late RepoFixture f;
  late MediaRepo repo;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    f = await RepoFixture.seed(db);
    repo = MediaRepo(db);
  });

  tearDown(() => db.close());

  test('linkedTo returns rows in link order through live links', () async {
    final obs = await f.record();
    final second = await f.media(entityId: obs, sortOrder: 1, role: 'attachment');
    final first = await f.media(entityId: obs, sortOrder: 0);
    final voice = await f.media(
      entityId: obs,
      sortOrder: 2,
      mediaType: 'audio',
      role: 'attachment',
    );
    final dropped = await f.media(entityId: obs, sortOrder: 3, role: 'attachment');
    await (db.update(db.mediaLinks)..where((l) => l.mediaId.equals(dropped)))
        .write(MediaLinksCompanion(deletedAt: Value(f.now)));

    final rows = await repo.linkedTo(entityId: obs);
    expect(rows.map((m) => m.id), [first, second, voice]);
    expect(rows.last.mediaType, 'audio');
    expect(await repo.linkedTo(entityId: 'nothing'), isEmpty);
  });

  test('unlink removes one link; liveLinkCount sees what is left', () async {
    final a = await f.record();
    final b = await f.record();
    final shared = await f.media(entityId: a);
    await db
        .into(db.mediaLinks)
        .insert(
          MediaLinksCompanion.insert(
            id: newId(),
            propertyId: f.propertyId,
            mediaId: shared,
            entityType: 'observation',
            entityId: b,
            createdAt: f.now,
          ),
        );
    expect(await repo.liveLinkCount(shared), 2);
    await repo.unlink(shared, entityId: a);
    expect(await repo.liveLinkCount(shared), 1);
    expect(await repo.linkedTo(entityId: a), isEmpty);
    expect((await repo.linkedTo(entityId: b)).single.id, shared);
  });

  test('erase takes the row, its links and its files', () async {
    final tmp = Directory.systemTemp.createTempSync('media_repo');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final obs = await f.record();
    final id = await f.media(
      entityId: obs,
      localPath: p.join(tmp.path, 'x.jpg'),
    );
    final file = File(p.join(tmp.path, 'x.jpg'))..writeAsBytesSync([1, 2]);
    await (db.update(db.media)..where((m) => m.id.equals(id))).write(
      MediaCompanion(thumbPath: Value(p.join(tmp.path, 'x.thumb.jpg'))),
    );
    final thumb = File(p.join(tmp.path, 'x.thumb.jpg'))..writeAsBytesSync([1]);

    await repo.erase(id);
    expect(await repo.byId(id), isNull);
    expect(await repo.liveLinkCount(id), 0);
    expect(file.existsSync(), isFalse);
    expect(thumb.existsSync(), isFalse);
  });

  test('changes fires for a link write', () async {
    var ticks = 0;
    final sub = repo.changes.listen((_) => ticks++);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 1);
    final obs = await f.record();
    await f.media(entityId: obs);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, greaterThanOrEqualTo(2));
    await sub.cancel();
  });
}
