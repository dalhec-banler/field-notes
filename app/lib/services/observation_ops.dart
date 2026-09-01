import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../db/database.dart';

/// Erase an observation as if it were never written: the row, its
/// identification suggestions, its media links, the media rows and their
/// files on disk, and its env-context row (when nothing else references it).
/// Used by the save-toast UNDO, where the record is seconds old and a
/// tombstone would still drag the photo into the next backup and export.
///
/// The row work runs in one transaction; files are removed only after it
/// commits, so a failure can't leave a half-erased record.
Future<void> eraseObservation(FieldNotesDb db, String observationId) async {
  final files = <String>[];

  await db.transaction(() async {
    final obs = await (db.select(
      db.observations,
    )..where((o) => o.id.equals(observationId))).getSingleOrNull();
    if (obs == null) return;

    final links =
        await (db.select(db.mediaLinks)..where(
              (l) =>
                  l.entityType.equals('observation') &
                  l.entityId.equals(observationId),
            ))
            .get();
    final mediaIds = links.map((l) => l.mediaId).toSet();

    // Order follows the foreign keys: suggestions and links first, then
    // media, then the observation (it references its env context), then the
    // context.
    await (db.delete(
      db.identificationSuggestions,
    )..where((s) => s.observationId.equals(observationId))).go();
    await (db.delete(db.mediaLinks)..where(
          (l) =>
              l.entityType.equals('observation') &
              l.entityId.equals(observationId),
        ))
        .go();

    for (final mediaId in mediaIds) {
      // Only remove media that nothing else links to.
      final otherLinks = await (db.select(
        db.mediaLinks,
      )..where((l) => l.mediaId.equals(mediaId))).get();
      if (otherLinks.isNotEmpty) continue;
      final m = await (db.select(
        db.media,
      )..where((x) => x.id.equals(mediaId))).getSingleOrNull();
      if (m == null) continue;
      files.addAll(mediaFilePaths(m));
      await (db.delete(db.media)..where((x) => x.id.equals(mediaId))).go();
    }

    await (db.delete(
      db.observations,
    )..where((o) => o.id.equals(observationId))).go();

    // Every capture creates its own env-context row, so nothing else
    // (planting events, plant checks, visits) can point at this one; the
    // observation check is belt-and-braces.
    final envId = obs.envContextId;
    if (envId != null) {
      final stillUsed =
          await (db.select(db.observations)
                ..where((o) => o.envContextId.equals(envId))
                ..limit(1))
              .get();
      if (stillUsed.isEmpty) {
        await (db.delete(
          db.envContexts,
        )..where((e) => e.id.equals(envId))).go();
      }
    }
  });

  deleteFiles(files);
}

/// The photos linked to an observation, in link order (`sort_order`, the
/// order capture wrote them), restricted to rows whose file is on disk.
/// This is the one place that decides what "the record's photos" means —
/// identification callers hand the whole list on (spec §5: every photo of
/// the record goes to Pl@ntNet, up to its limit of five).
Future<List<File>> observationPhotoFiles(
  FieldNotesDb db,
  String observationId,
) async {
  final links =
      await (db.select(db.mediaLinks)
            ..where(
              (l) =>
                  l.entityType.equals('observation') &
                  l.entityId.equals(observationId) &
                  l.deletedAt.isNull(),
            )
            ..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]))
          .get();
  if (links.isEmpty) return const [];
  final rows =
      await (db.select(db.media)..where(
            (m) =>
                m.id.isIn([for (final l in links) l.mediaId]) &
                m.mediaType.equals('photo') &
                m.deletedAt.isNull(),
          ))
          .get();
  final byId = {for (final m in rows) m.id: m};
  final files = <File>[];
  for (final link in links) {
    final path = byId[link.mediaId]?.localPath;
    if (path == null) continue;
    final f = File(path);
    if (f.existsSync()) files.add(f);
  }
  return files;
}

/// Original, working copy and thumbnail for a media row.
List<String> mediaFilePaths(MediaData m) {
  final paths = <String>[];
  if (m.localPath != null) {
    paths.add(m.localPath!);
    paths.add(p.setExtension(p.withoutExtension(m.localPath!), '.work.jpg'));
  }
  if (m.thumbPath != null) paths.add(m.thumbPath!);
  return paths;
}

/// Remove a media row and its files — for a photo that was written but whose
/// record never landed.
Future<void> eraseMedia(FieldNotesDb db, String mediaId) async {
  final m = await (db.select(
    db.media,
  )..where((x) => x.id.equals(mediaId))).getSingleOrNull();
  if (m == null) return;
  await (db.delete(
    db.mediaLinks,
  )..where((l) => l.mediaId.equals(mediaId))).go();
  await (db.delete(db.media)..where((x) => x.id.equals(mediaId))).go();
  deleteFiles(mediaFilePaths(m));
}

void deleteFiles(Iterable<String> paths) {
  for (final path in paths.toSet()) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // A leftover file is not worth failing over.
    }
  }
}
