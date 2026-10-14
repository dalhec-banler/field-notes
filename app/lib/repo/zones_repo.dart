import '../db/database.dart';

/// Reads on `zones`. The two list shapes keep the names D-037 gave them:
/// [of] is every live zone, hidden included; [toDraw] is what paints.
class ZonesRepo {
  ZonesRepo(this.db);

  final FieldNotesDb db;

  Future<Zone?> byId(String id) =>
      (db.select(db.zones)..where((z) => z.id.equals(id))).getSingleOrNull();

  /// Every zone this place still has — hidden ones included. See
  /// [FieldNotesDb.zonesOf].
  Future<List<Zone>> of(String propertyId, {bool byName = false}) =>
      db.zonesOf(propertyId, byName: byName);

  /// The zones that paint: live, not hidden, in name order.
  Future<List<Zone>> toDraw(String propertyId) => db.zonesToDraw(propertyId);

  Stream<void> get changes => db.changes({db.zones});
}
