import 'package:drift/drift.dart';

import '../db/database.dart';
import '../services/observation_ops.dart' as ops;
import '../sync/oplog.dart';

/// Reads on `media` and `media_links` as a record sees them. Writing a
/// new photo or recording stays with [MediaStore], which owns the files.
class MediaRepo {
  MediaRepo(this.db);

  final FieldNotesDb db;

  Future<MediaData?> byId(String id) =>
      (db.select(db.media)..where((m) => m.id.equals(id))).getSingleOrNull();

  /// The media rows linked to one entity, in link order (`sort_order`, the
  /// order capture wrote them), through live links only. A link whose media
  /// row is gone is skipped.
  Future<List<MediaData>> linkedTo({
    String entityType = 'observation',
    required String entityId,
  }) async {
    final links =
        await (db.select(db.mediaLinks)
              ..where(
                (l) =>
                    l.entityType.equals(entityType) &
                    l.entityId.equals(entityId) &
                    l.deletedAt.isNull(),
              )
              ..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]))
            .get();
    final out = <MediaData>[];
    for (final link in links) {
      final m = await byId(link.mediaId);
      if (m != null) out.add(m);
    }
    return out;
  }

  /// Take one media item off one entity. The row link goes; the media and
  /// its files stay until [liveLinkCount] says nothing else uses them.
  Future<void> unlink(
    String mediaId, {
    String entityType = 'observation',
    required String entityId,
  }) => (db.delete(db.mediaLinks)..where(
        (l) =>
            l.mediaId.equals(mediaId) &
            l.entityType.equals(entityType) &
            l.entityId.equals(entityId),
      ))
      .go();

  /// How many live links still point at a media row.
  Future<int> liveLinkCount(String mediaId) async {
    final rows = await (db.select(
      db.mediaLinks,
    )..where((l) => l.mediaId.equals(mediaId) & l.deletedAt.isNull())).get();
    return rows.length;
  }

  /// Remove a media row and its files (services/observation_ops.dart).
  Future<void> erase(String mediaId, {OpLog? log}) =>
      ops.eraseMedia(db, mediaId, log: log);

  Stream<void> get changes => db.changes({db.media, db.mediaLinks});
}
