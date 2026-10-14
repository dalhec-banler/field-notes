import 'package:drift/drift.dart';

import '../db/database.dart';

/// Reads and the one write on `photo_points`: a station pinned from a
/// record, on capture or afterwards.
class PhotoPointsRepo {
  PhotoPointsRepo(this.db);

  final FieldNotesDb db;

  Future<PhotoPoint?> byId(String id) =>
      (db.select(db.photoPoints)..where((p) => p.id.equals(id)))
          .getSingleOrNull();

  /// Every live station on a place.
  Future<List<PhotoPoint>> on(String propertyId) =>
      (db.select(db.photoPoints)
            ..where((p) => p.propertyId.equals(propertyId))
            ..where((p) => p.deletedAt.isNull()))
          .get();

  /// The station (if any) whose reference frame is one of [mediaIds].
  Future<PhotoPoint?> anchoredBy(List<String> mediaIds) {
    if (mediaIds.isEmpty) return Future.value(null);
    return (db.select(db.photoPoints)
          ..where((p) => p.referenceMediaId.isIn(mediaIds))
          ..where((p) => p.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
  }

  /// Pin a station: same spot, same aim, every visit from here on. The
  /// defaults (90-day cadence, 26 mm, 60 m extent) are the ones capture and
  /// the record screen have always written; [now] lets a caller stamp it
  /// with the same instant as the record it came from.
  Future<String> create({
    required String propertyId,
    required String name,
    required double lat,
    required double lng,
    required double bearingDeg,
    String? subject,
    String? referenceMediaId,
    String? now,
  }) async {
    final at = now ?? nowUtcIso();
    final id = newId();
    await db
        .into(db.photoPoints)
        .insert(
          PhotoPointsCompanion.insert(
            id: id,
            propertyId: propertyId,
            name: name,
            lat: lat,
            lng: lng,
            bearingDeg: bearingDeg,
            subject: Value(subject),
            cadenceDays: const Value(90),
            focalLengthMm: const Value(26),
            viewExtentM: const Value(60),
            referenceMediaId: Value(referenceMediaId),
            createdBy: 'local',
            createdAt: at,
            updatedAt: at,
          ),
        );
    return id;
  }

  Stream<void> get changes => db.changes({db.photoPoints});
}
