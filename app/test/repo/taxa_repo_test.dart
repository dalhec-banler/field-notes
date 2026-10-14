import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/repo/taxa_repo.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

void main() {
  late FieldNotesDb db;
  late RepoFixture f;
  late TaxaRepo repo;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    f = await RepoFixture.seed(db);
    repo = TaxaRepo(db);
  });

  tearDown(() => db.close());

  Future<String> taxon(String sci, {String? common}) async {
    final id = newId();
    await db
        .into(db.taxa)
        .insert(
          TaxaCompanion.insert(
            id: id,
            scientificName: sci,
            commonName: Value(common),
            createdAt: f.now,
            updatedAt: f.now,
          ),
        );
    return id;
  }

  test('byId', () async {
    expect((await repo.byId(f.burOakId))?.commonName, 'Bur Oak');
    expect(await repo.byId('nope'), isNull);
  });

  test('withRecordsOn counts live records per species, most first', () async {
    final pecan = await taxon('Carya illinoinensis', common: 'Pecan');
    final unnamed = await taxon('Yucca rupicola');
    await taxon('Never recorded', common: 'Absent');
    await f.record(type: 'plant', taxonId: pecan);
    await f.record(type: 'plant', taxonId: pecan);
    await f.record(type: 'plant', taxonId: pecan);
    await f.record(type: 'plant', taxonId: f.burOakId);
    final deleted = await f.record(type: 'plant', taxonId: f.burOakId);
    await (db.update(db.observations)..where((o) => o.id.equals(deleted)))
        .write(ObservationsCompanion(deletedAt: Value(f.now)));
    await f.record(type: 'plant', taxonId: unnamed);

    final rows = await repo.withRecordsOn(f.propertyId);
    // Ties break on common_name ascending, and SQLite sorts NULL first —
    // so the species with no common name lands before Bur Oak.
    expect(rows.map((r) => r.taxonId), [pecan, unnamed, f.burOakId]);
    expect(rows.map((r) => r.count), [3, 1, 1]);
    expect(rows.first.label, 'Pecan');
    expect(rows[1].label, 'Yucca rupicola');
  });

  test('changes fires on a taxon write', () async {
    var ticks = 0;
    final sub = repo.changes.listen((_) => ticks++);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 1);
    await taxon('Ulmus crassifolia');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 2);
    await sub.cancel();
  });
}
