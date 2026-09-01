import 'package:drift/drift.dart';

import '../db/database.dart';

/// Pending-visible review (SYNC-DESIGN.md, Austin's model).
///
/// The rules, in full:
///  * A contributor's edit applies everywhere immediately and gets ONE
///    `review_items` row, state `pending`. Everyone sees the edit; everyone
///    sees the tag.
///  * The steward approves (tag clears) or removes (the entity is
///    tombstoned, the review row says so and by whom). Approval is not
///    final — [remove] works on an approved item too. Final say never
///    expires.
///  * The steward's own edits are born approved: no row at all. Absence of
///    a review row means "not subject to review", which keeps every
///    pre-sharing database valid with zero migration of old rows.
///
/// Until sharing ships (M4b) every writer is the owner, so nothing in the
/// app creates pending rows yet — the service and its UI are live but
/// naturally empty. The one caller today is the sync-apply path of the
/// future; the tests are the spec.
class ReviewService {
  ReviewService(this.db);

  final FieldNotesDb db;

  /// Devices whose author id is the property owner skip review entirely.
  /// Until members exist, everyone is the owner.
  Future<void> markPending({
    required String propertyId,
    required String entityType,
    required String entityId,
    required String author,
  }) async {
    final now = nowUtcIso();
    await db.into(db.reviewItems).insert(
          ReviewItemsCompanion.insert(
            id: newId(),
            propertyId: propertyId,
            entityType: entityType,
            entityId: entityId,
            author: author,
            createdAt: now,
            updatedAt: now,
          ),
          // An edit to an already-tracked entity re-opens review: the
          // steward ruled on what it was, not on what it now says.
          onConflict: DoUpdate(
            (old) => ReviewItemsCompanion(
              state: const Value('pending'),
              decidedBy: const Value(null),
              decidedAt: const Value(null),
              updatedAt: Value(now),
            ),
            target: [db.reviewItems.entityType, db.reviewItems.entityId],
          ),
        );
  }

  Future<void> approve(String reviewItemId, {required String by}) =>
      _decide(reviewItemId, 'approved', by: by);

  /// Remove the edit from view: the review row records the ruling and the
  /// underlying entity is soft-deleted, so the change syncs like any other
  /// and the author can see it was removed rather than finding it silently
  /// gone. Works on pending AND approved items — "even after I approve
  /// them".
  Future<void> remove(String reviewItemId,
      {required String by, String? note}) async {
    final item = await (db.select(db.reviewItems)
          ..where((r) => r.id.equals(reviewItemId)))
        .getSingle();
    await _decide(reviewItemId, 'removed', by: by, note: note);
    await _tombstoneEntity(item.entityType, item.entityId);
  }

  Future<void> _decide(String id, String state,
      {required String by, String? note}) async {
    await (db.update(db.reviewItems)..where((r) => r.id.equals(id)))
        .write(ReviewItemsCompanion(
      state: Value(state),
      decidedBy: Value(by),
      decidedAt: Value(nowUtcIso()),
      note: Value(note),
      updatedAt: Value(nowUtcIso()),
    ));
  }

  Future<void> _tombstoneEntity(String entityType, String entityId) async {
    final now = nowUtcIso();
    // Soft delete only — hard erase would be un-syncable and unattributable.
    switch (entityType) {
      case 'observation':
        await (db.update(db.observations)..where((o) => o.id.equals(entityId)))
            .write(ObservationsCompanion(
                deletedAt: Value(now), updatedAt: Value(now)));
      case 'zone':
        await (db.update(db.zones)..where((z) => z.id.equals(entityId)))
            .write(
                ZonesCompanion(deletedAt: Value(now), updatedAt: Value(now)));
      case 'feature':
        await (db.update(db.features)..where((f) => f.id.equals(entityId)))
            .write(FeaturesCompanion(
                deletedAt: Value(now), updatedAt: Value(now)));
      case 'planting_event':
        await (db.update(db.plantingEvents)
              ..where((e) => e.id.equals(entityId)))
            .write(PlantingEventsCompanion(
                deletedAt: Value(now), updatedAt: Value(now)));
      case 'plant_checkin':
        await (db.update(db.plantCheckins)
              ..where((c) => c.id.equals(entityId)))
            .write(PlantCheckinsCompanion(
                deletedAt: Value(now), updatedAt: Value(now)));
      default:
        // Remaining entity types tombstone the same way as sync lands for
        // them; refusing loudly beats silently "removing" nothing.
        throw UnsupportedError('remove not wired for $entityType yet');
    }
  }

  /// The steward's feed: pending first, newest first.
  Future<List<ReviewItem>> pending(String propertyId) =>
      (db.select(db.reviewItems)
            ..where((r) => r.propertyId.equals(propertyId))
            ..where((r) => r.state.equals('pending'))
            ..where((r) => r.deletedAt.isNull())
            ..orderBy([(r) => OrderingTerm.desc(r.createdAt)]))
          .get();

  /// Everything ever ruled on, for the history view.
  Future<List<ReviewItem>> decided(String propertyId) =>
      (db.select(db.reviewItems)
            ..where((r) => r.propertyId.equals(propertyId))
            ..where((r) => r.state.equals('pending').not())
            ..where((r) => r.deletedAt.isNull())
            ..orderBy([(r) => OrderingTerm.desc(r.decidedAt)]))
          .get();

  /// Live count for the badge on the steward's screen.
  Stream<int> pendingCount(String propertyId) {
    final count = db.reviewItems.id.count();
    final q = db.selectOnly(db.reviewItems)
      ..addColumns([count])
      ..where(db.reviewItems.propertyId.equals(propertyId) &
          db.reviewItems.state.equals('pending') &
          db.reviewItems.deletedAt.isNull());
    return q.map((r) => r.read(count) ?? 0).watchSingle();
  }

  /// The tag for one entity, or null when it isn't subject to review
  /// (owner-authored, or made before sharing existed).
  Future<ReviewItem?> forEntity(String entityType, String entityId) =>
      (db.select(db.reviewItems)
            ..where((r) => r.entityType.equals(entityType))
            ..where((r) => r.entityId.equals(entityId))
            ..where((r) => r.deletedAt.isNull()))
          .getSingleOrNull();
}
