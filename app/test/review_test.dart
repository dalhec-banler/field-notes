import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/review.dart';
import 'package:flutter_test/flutter_test.dart';

/// Austin's pending-visible review model, as executable spec:
/// visible immediately + tagged, steward approves or removes, approval is
/// revocable forever, re-edits reopen review, removal tombstones (soft).
void main() {
  late FieldNotesDb db;
  late ReviewService service;
  late String propId;

  Future<String> seedObservation() async {
    final now = nowUtcIso();
    final id = newId();
    await db.into(db.observations).insert(ObservationsCompanion.insert(
          id: id,
          propertyId: propId,
          observedAt: now,
          localTz: 'CDT',
          lat: 31.05,
          lng: -98.18,
          notes: const Value('wylder found a madrone'),
          createdBy: 'wylder',
          createdAt: now,
          updatedAt: now,
        ));
    return id;
  }

  setUp(() async {
    db = FieldNotesDb.forTesting();
    service = ReviewService(db);
    final now = nowUtcIso();
    propId = newId();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
          id: propId,
          name: 'Shorts Resort',
          createdBy: 'austin',
          createdAt: now,
          updatedAt: now,
        ));
  });

  tearDown(() => db.close());

  test('a contributor edit is visible AND tagged pending', () async {
    final obsId = await seedObservation();
    await service.markPending(
        propertyId: propId,
        entityType: 'observation',
        entityId: obsId,
        author: 'wylder');

    // Visible: the record itself is a live row like any other.
    final obs = await (db.select(db.observations)
          ..where((o) => o.id.equals(obsId)))
        .getSingle();
    expect(obs.deletedAt, isNull);

    // Tagged: exactly one pending item points at it.
    final item = await service.forEntity('observation', obsId);
    expect(item!.state, 'pending');
    expect(item.author, 'wylder');
    expect((await service.pending(propId)).length, 1);
  });

  test('approve clears the tag; the record stays', () async {
    final obsId = await seedObservation();
    await service.markPending(
        propertyId: propId,
        entityType: 'observation',
        entityId: obsId,
        author: 'wylder');
    final item = await service.forEntity('observation', obsId);

    await service.approve(item!.id, by: 'austin');

    final after = await service.forEntity('observation', obsId);
    expect(after!.state, 'approved');
    expect(after.decidedBy, 'austin');
    expect(await service.pending(propId), isEmpty);
    expect((await service.decided(propId)).single.state, 'approved');
  });

  test('remove tombstones the record — soft, never an erase', () async {
    final obsId = await seedObservation();
    await service.markPending(
        propertyId: propId,
        entityType: 'observation',
        entityId: obsId,
        author: 'wylder');
    final item = await service.forEntity('observation', obsId);

    await service.remove(item!.id, by: 'austin', note: 'off property');

    final obs = await (db.select(db.observations)
          ..where((o) => o.id.equals(obsId)))
        .getSingle();
    expect(obs.deletedAt, isNotNull,
        reason: 'soft delete: syncable, attributable, reversible');
    final after = await service.forEntity('observation', obsId);
    expect(after!.state, 'removed');
    expect(after.note, 'off property');
  });

  test('final say has no expiry: remove works on an APPROVED item',
      () async {
    final obsId = await seedObservation();
    await service.markPending(
        propertyId: propId,
        entityType: 'observation',
        entityId: obsId,
        author: 'wylder');
    final item = await service.forEntity('observation', obsId);
    await service.approve(item!.id, by: 'austin');

    // Weeks later, the steward changes their mind.
    await service.remove(item.id, by: 'austin');

    final obs = await (db.select(db.observations)
          ..where((o) => o.id.equals(obsId)))
        .getSingle();
    expect(obs.deletedAt, isNotNull);
    expect((await service.forEntity('observation', obsId))!.state, 'removed');
  });

  test('editing a ruled-on entity reopens review', () async {
    final obsId = await seedObservation();
    await service.markPending(
        propertyId: propId,
        entityType: 'observation',
        entityId: obsId,
        author: 'wylder');
    final item = await service.forEntity('observation', obsId);
    await service.approve(item!.id, by: 'austin');

    // Wylder edits the approved record → the tag comes back; the steward
    // ruled on what it was, not on what it now says.
    await service.markPending(
        propertyId: propId,
        entityType: 'observation',
        entityId: obsId,
        author: 'wylder');

    final after = await service.forEntity('observation', obsId);
    expect(after!.state, 'pending');
    expect(after.decidedBy, isNull);
    expect((await service.pending(propId)).length, 1,
        reason: 'still one row per entity — reopened, not duplicated');
  });

  test('pendingCount stream feeds the badge', () async {
    final counts = <int>[];
    final sub = service.pendingCount(propId).listen(counts.add);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final obsId = await seedObservation();
    await service.markPending(
        propertyId: propId,
        entityType: 'observation',
        entityId: obsId,
        author: 'wylder');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(counts.first, 0);
    expect(counts.last, 1);
    await sub.cancel();
  });
}
