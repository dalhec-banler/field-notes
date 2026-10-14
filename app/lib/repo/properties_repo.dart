import 'package:drift/drift.dart';

import '../db/database.dart';

/// Reads on `properties`.
class PropertiesRepo {
  PropertiesRepo(this.db);

  final FieldNotesDb db;

  Future<Property?> byId(String id) =>
      (db.select(db.properties)..where((p) => p.id.equals(id)))
          .getSingleOrNull();

  /// Every place that hasn't been removed, in name order.
  Future<List<Property>> live() =>
      (db.select(db.properties)
            ..where((p) => p.deletedAt.isNull())
            ..orderBy([(p) => OrderingTerm.asc(p.name)]))
          .get();

  Stream<void> get changes => db.changes({db.properties});
}
