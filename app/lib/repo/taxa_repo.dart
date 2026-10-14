import 'package:drift/drift.dart';

import '../db/database.dart';

/// A species with the number of live records naming it on one place.
class SpeciesCount {
  const SpeciesCount({
    required this.taxonId,
    required this.scientificName,
    required this.count,
    this.commonName,
  });

  final String taxonId;
  final String scientificName;
  final String? commonName;
  final int count;

  /// What a picker shows: the common name when there is one.
  String get label => commonName ?? scientificName;
}

/// Reads on `taxa` as the record flows need them. The library's own
/// loaders and lookups stay in `species/`.
class TaxaRepo {
  TaxaRepo(this.db);

  final FieldNotesDb db;

  Future<TaxaData?> byId(String id) =>
      (db.select(db.taxa)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Species that actually have records on this place — not the whole
  /// library — most-recorded first, then by common name.
  Future<List<SpeciesCount>> withRecordsOn(String propertyId) async {
    final rows = await db
        .customSelect(
          'SELECT t.id AS id, t.common_name AS common, t.scientific_name AS sci, '
          'COUNT(o.id) AS n FROM taxa t '
          'JOIN observations o ON o.taxon_id = t.id '
          'WHERE o.property_id = ? AND o.deleted_at IS NULL '
          'GROUP BY t.id ORDER BY n DESC, common',
          variables: [Variable.withString(propertyId)],
          readsFrom: {db.taxa, db.observations},
        )
        .get();
    return [
      for (final r in rows)
        SpeciesCount(
          taxonId: r.data['id'] as String,
          commonName: r.data['common'] as String?,
          scientificName: r.data['sci'] as String,
          count: r.data['n'] as int,
        ),
    ];
  }

  Stream<void> get changes => db.changes({db.taxa});
}
