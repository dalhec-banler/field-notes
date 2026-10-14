import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../sync/oplog.dart';
import 'diag.dart';

/// What the save-toast UNDO did with the record.
enum UndoOutcome {
  /// Hard-erased: no device had been told about it, and none will be.
  erased,

  /// Soft-deleted: its insert had already been pushed, so the peer gets a
  /// tombstone instead of a row that quietly stops matching.
  tombstoned,
}

/// The save-toast UNDO (SYNC-DESIGN, "one real casualty"; D-038 item 12).
///
/// The rule: if the record's insert op is already at or below a push mark
/// — some store has it, so some peer may have it — UNDO is a soft delete
/// ([softDeleteObservation]), and the tombstone travels on the next sync.
/// If no store has been given any op of the row, UNDO is the hard erase it
/// always was ([eraseObservation]), and the row's pending ops go with it so
/// the peer never learns the record existed. With no op log at all (capture
/// failed to start), nothing could have been pushed, and erase stays erase.
Future<UndoOutcome> undoObservation(
  FieldNotesDb db,
  String observationId, {
  OpLog? log,
}) async {
  if (log != null && await log.hasBeenPushed('observations', observationId)) {
    await softDeleteObservation(db, observationId);
    return UndoOutcome.tombstoned;
  }
  await eraseObservation(db, observationId, log: log);
  return UndoOutcome.erased;
}

/// Erase an observation as if it were never written: the row, its
/// identification suggestions, its media links, the media rows and their
/// files on disk, and its env-context row (when nothing else references it).
/// Used by the save-toast UNDO, where the record is seconds old and a
/// tombstone would still drag the photo into the next backup and export.
///
/// The row work runs in one transaction; files are removed only after it
/// commits, so a failure can't leave a half-erased record. With a [log],
/// the ops of every row erased that no store has seen are dropped in the
/// same transaction; a row some store HAS seen keeps its ops, and its
/// deletion travels as a tombstone.
Future<void> eraseObservation(
  FieldNotesDb db,
  String observationId, {
  OpLog? log,
}) async {
  final files = <String>[];
  final erased = <(String, String)>[];

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
    for (final l in links) {
      erased.add(('media_links', l.id));
    }
    final suggestions = await (db.select(
      db.identificationSuggestions,
    )..where((s) => s.observationId.equals(observationId))).get();
    for (final s in suggestions) {
      erased.add(('identification_suggestions', s.id));
    }

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
      erased.add(('media', mediaId));
    }

    await (db.delete(
      db.observations,
    )..where((o) => o.id.equals(observationId))).go();
    erased.add(('observations', observationId));

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
        erased.add(('env_contexts', envId));
      }
    }

    // Still inside the transaction: the delete triggers have just written
    // their tombstones, and for a row no store has seen those go too.
    if (log != null) await log.forgetUnpushed(erased);
  });

  deleteFiles(files);
}

/// Soft delete (spec §4.1): the record leaves the ledger, its photos stay
/// on disk, and sync engines get the tombstone they need. The one write the
/// record screen's DELETE makes.
Future<void> softDeleteObservation(FieldNotesDb db, String observationId) {
  final now = nowUtcIso();
  return (db.update(
    db.observations,
  )..where((o) => o.id.equals(observationId))).write(
    ObservationsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
  );
}

/// The edit sheet's write: name, confidence, type, day and notes land
/// together, and nothing else on the row moves.
Future<void> applyRecordEdit(
  FieldNotesDb db,
  String observationId, {
  required String? taxonId,
  required String? taxonConfidence,
  required String observationType,
  required String observedAt,
  required String? notes,
}) {
  final text = notes?.trim();
  return (db.update(
    db.observations,
  )..where((o) => o.id.equals(observationId))).write(
    ObservationsCompanion(
      taxonId: Value(taxonId),
      taxonConfidence: Value(taxonConfidence),
      observationType: Value(observationType),
      observedAt: Value(observedAt),
      notes: Value(text == null || text.isEmpty ? null : text),
      updatedAt: Value(nowUtcIso()),
    ),
  );
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
/// record never landed, or one taken off a record. Same rule as
/// [eraseObservation]: with a [log], a row no store has seen leaves no op
/// behind; one a store has seen travels as a tombstone.
Future<void> eraseMedia(FieldNotesDb db, String mediaId, {OpLog? log}) async {
  final m = await (db.select(
    db.media,
  )..where((x) => x.id.equals(mediaId))).getSingleOrNull();
  if (m == null) return;
  await db.transaction(() async {
    final links = await (db.select(
      db.mediaLinks,
    )..where((l) => l.mediaId.equals(mediaId))).get();
    await (db.delete(
      db.mediaLinks,
    )..where((l) => l.mediaId.equals(mediaId))).go();
    await (db.delete(db.media)..where((x) => x.id.equals(mediaId))).go();
    if (log != null) {
      await log.forgetUnpushed([
        for (final l in links) ('media_links', l.id),
        ('media', mediaId),
      ]);
    }
  });
  deleteFiles(mediaFilePaths(m));
}

void deleteFiles(Iterable<String> paths) {
  for (final path in paths.toSet()) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (e, st) {
      Diag.report(e, st, where: 'observation_ops.deleteFiles');
      // A leftover file is not worth failing over.
    }
  }
}
