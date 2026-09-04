import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/env_context.dart';
import 'package:field_notes/services/observation_ops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late FieldNotesDb db;
  late Directory tmp;
  late String propId;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    tmp = Directory.systemTemp.createTempSync('obs_ops');
    final now = nowUtcIso();
    propId = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propId,
            name: 'Yard',
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        );
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  /// Mirrors what the capture screen writes: observation + env context +
  /// media row with original/work/thumb files + link.
  Future<(String obsId, String mediaId, List<String> files)> writeCapture({
    String? sharedMediaId,
  }) async {
    final now = nowUtcIso();
    final obsId = newId();
    final envId = await EnvContextService(db).createStale(
      propertyId: propId,
      lat: 30.26,
      lng: -97.72,
      resolvedFor: '2026-08-26',
    );
    await db
        .into(db.observations)
        .insert(
          ObservationsCompanion.insert(
            id: obsId,
            propertyId: propId,
            observedAt: now,
            localTz: 'CDT',
            lat: 30.26,
            lng: -97.72,
            envContextId: Value(envId),
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        );

    final mediaId = sharedMediaId ?? newId();
    final files = <String>[];
    if (sharedMediaId == null) {
      final original = File(p.join(tmp.path, '$mediaId.jpg'))
        ..writeAsBytesSync([1, 2, 3]);
      final work = File(p.join(tmp.path, '$mediaId.work.jpg'))
        ..writeAsBytesSync([1, 2]);
      final thumb = File(p.join(tmp.path, '$mediaId.thumb.jpg'))
        ..writeAsBytesSync([1]);
      files.addAll([original.path, work.path, thumb.path]);
      await db
          .into(db.media)
          .insert(
            MediaCompanion.insert(
              id: mediaId,
              propertyId: propId,
              mediaType: 'photo',
              localPath: Value(original.path),
              thumbPath: Value(thumb.path),
              createdBy: 'a',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    await db
        .into(db.mediaLinks)
        .insert(
          MediaLinksCompanion.insert(
            id: newId(),
            propertyId: propId,
            mediaId: mediaId,
            entityType: 'observation',
            entityId: obsId,
            role: const Value('primary'),
            createdAt: now,
          ),
        );
    return (obsId, mediaId, files);
  }

  test('erase removes row, link, media, files and env context', () async {
    final (obsId, mediaId, files) = await writeCapture();
    expect(files.every((f) => File(f).existsSync()), isTrue);

    await eraseObservation(db, obsId);

    expect(
      await (db.select(
        db.observations,
      )..where((o) => o.id.equals(obsId))).getSingleOrNull(),
      isNull,
    );
    expect(
      await (db.select(
        db.mediaLinks,
      )..where((l) => l.entityId.equals(obsId))).get(),
      isEmpty,
    );
    expect(
      await (db.select(
        db.media,
      )..where((m) => m.id.equals(mediaId))).getSingleOrNull(),
      isNull,
    );
    expect(await db.select(db.envContexts).get(), isEmpty);
    expect(
      files.any((f) => File(f).existsSync()),
      isFalse,
      reason: 'original, working copy and thumbnail all gone',
    );
  });

  test('erase keeps media that another record still links to', () async {
    final (obsA, mediaId, files) = await writeCapture();
    final (obsB, _, _) = await writeCapture(sharedMediaId: mediaId);

    await eraseObservation(db, obsA);

    expect(
      await (db.select(
        db.media,
      )..where((m) => m.id.equals(mediaId))).getSingleOrNull(),
      isNotNull,
    );
    expect(files.every((f) => File(f).existsSync()), isTrue);
    expect(
      await (db.select(
        db.mediaLinks,
      )..where((l) => l.entityId.equals(obsB))).get(),
      hasLength(1),
    );
  });

  test('erase of an unknown id is a no-op', () async {
    await eraseObservation(db, 'nope');
  });
}
