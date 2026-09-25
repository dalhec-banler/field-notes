import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/taxa_dedupe.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two loaders could file one plant twice — under both of its accepted names,
/// or twice over from a list that named it twice. These cover the fold-down.
void main() {
  late FieldNotesDb db;
  setUp(() => db = FieldNotesDb.forTesting());
  tearDown(() => db.close());

  Future<String> taxon(
    String name, {
    String? synonyms,
    String? common,
    String? nativity,
    String? propertyId,
    String? createdBy,
    String createdAt = '2026-01-01T00:00:00.000Z',
  }) async {
    final id = newId();
    await db
        .into(db.taxa)
        .insert(
          TaxaCompanion.insert(
            id: id,
            scientificName: name,
            synonyms: Value(synonyms),
            commonName: Value(common),
            nativity: Value(nativity),
            propertyId: Value(propertyId),
            createdBy: Value(createdBy),
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );
    return id;
  }

  Future<String> property() async {
    final id = newId();
    final now = nowUtcIso();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: id,
            name: 'Shorts',
            createdBy: 'test',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<String> observation(String propertyId, String taxonId) async {
    final id = newId();
    final now = nowUtcIso();
    await db
        .into(db.observations)
        .insert(
          ObservationsCompanion.insert(
            id: id,
            propertyId: propertyId,
            observedAt: now,
            localTz: 'America/Chicago',
            lat: 31.0,
            lng: -98.0,
            taxonId: Value(taxonId),
            createdBy: 'test',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<List<String>> living() async {
    final rows = await (db.select(
      db.taxa,
    )..where((t) => t.deletedAt.isNull())).get();
    return rows.map((t) => t.scientificName).toList()..sort();
  }

  test('a plant listed twice under one name ends up as one row', () async {
    await taxon('Sambucus canadensis');
    await taxon('Sambucus canadensis', createdAt: '2026-02-01T00:00:00.000Z');

    expect(await dedupeTaxa(db, now: nowUtcIso()), 1);
    expect(await living(), ['Sambucus canadensis']);
  });

  test('the two accepted names for one plant meet through the synonym', () async {
    // Agarita: the seed filed it under Mahonia with Berberis as a synonym,
    // the state list filed Berberis fresh.
    await taxon(
      'Mahonia trifoliolata',
      synonyms: 'Berberis trifoliolata',
      common: 'Agarita',
    );
    await taxon('Berberis trifoliolata', nativity: 'native');

    expect(await dedupeTaxa(db, now: nowUtcIso()), 1);
    final rows = await (db.select(
      db.taxa,
    )..where((t) => t.deletedAt.isNull())).get();
    expect(rows, hasLength(1));
    // Both names survive on the row, so a later import finds it either way.
    expect(rows.single.synonyms, 'Berberis trifoliolata');
    // And the column only the retired row had filled comes across.
    expect(rows.single.nativity, 'native');
    expect(rows.single.commonName, 'Agarita');
  });

  test('records follow the plant, not the row that happened to lose', () async {
    // The honey mesquite case: the observation sits on the row the seed made,
    // and the state list's row is the newer one.
    final p = await property();
    final seeded = await taxon('Prosopis glandulosa');
    final fromList = await taxon(
      'Neltuma glandulosa',
      synonyms: 'Prosopis glandulosa',
      createdAt: '2026-02-01T00:00:00.000Z',
    );
    final obs = await observation(p, fromList);

    await dedupeTaxa(db, now: nowUtcIso());

    final kept = await (db.select(
      db.taxa,
    )..where((t) => t.deletedAt.isNull())).getSingle();
    // History decides the survivor, so nothing has to be re-pointed.
    expect(kept.id, fromList);
    expect(kept.id, isNot(seeded));
    final o = await (db.select(
      db.observations,
    )..where((t) => t.id.equals(obs))).getSingle();
    expect(o.taxonId, kept.id, reason: 'no record may point at a retired row');
  });

  test('an observation on the retired row is moved across', () async {
    final p = await property();
    final a = await taxon('Berberis trifoliolata');
    final b = await taxon(
      'Mahonia trifoliolata',
      synonyms: 'Berberis trifoliolata',
      createdAt: '2026-02-01T00:00:00.000Z',
    );
    final onA = await observation(p, a);
    final onB = await observation(p, b);
    final onB2 = await observation(p, b);

    await dedupeTaxa(db, now: nowUtcIso());

    final kept = await (db.select(
      db.taxa,
    )..where((t) => t.deletedAt.isNull())).getSingle();
    expect(kept.id, b, reason: 'two records beats one');
    for (final id in [onA, onB, onB2]) {
      final o = await (db.select(
        db.observations,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(o.taxonId, kept.id);
    }
  });

  test('a twin the identification service made rejoins the library', () async {
    // The mesquite: a photo came back as Neltuma while the library only knew
    // Prosopis, so identification filed the record against the property.
    final p = await property();
    final shared = await taxon('Prosopis glandulosa', common: 'Honey Mesquite');
    final twin = await taxon(
      'Neltuma glandulosa',
      common: 'Honey mesquite',
      propertyId: p,
      createdBy: 'identification',
      createdAt: '2026-09-22T00:00:00.000Z',
    );
    final obs = await observation(p, twin);

    await dedupeTaxa(db, now: nowUtcIso());

    final kept = await (db.select(
      db.taxa,
    )..where((t) => t.deletedAt.isNull())).getSingle();
    // The shared row wins regardless of which one holds the record: a row
    // scoped to one property can't serve the library.
    expect(kept.id, shared);
    expect(kept.synonyms, 'Neltuma glandulosa');
    final o = await (db.select(
      db.observations,
    )..where((t) => t.id.equals(obs))).getSingle();
    expect(o.taxonId, shared);
  });

  test("a property's own taxon is left alone", () async {
    final p = await property();
    await taxon('Quercus nigra');
    await taxon('Quercus nigra', propertyId: p);

    expect(await dedupeTaxa(db, now: nowUtcIso()), 0);
    expect(await living(), ['Quercus nigra', 'Quercus nigra']);
  });

  test('two properties keep their own identified rows apart', () async {
    // Both were made by the service, but neither matches anything shared, so
    // there is no library row to rejoin and they must not merge into one
    // another — that would hand one property's record to the other.
    final a = await property();
    final b = await property();
    await taxon('Carya illinoinensis', propertyId: a, createdBy: 'identification');
    await taxon('Carya illinoinensis', propertyId: b, createdBy: 'identification');
    expect(await dedupeTaxa(db, now: nowUtcIso()), 0);
  });

  test('three rows chained by synonyms collapse to one', () async {
    // Lotebush arrived three ways; only the middle row names both others.
    await taxon('Ziziphus obtusifolia');
    await taxon('Condaliopsis obtusifolia', synonyms: 'Ziziphus obtusifolia');
    await taxon('Condalia obtusifolia', synonyms: 'Condaliopsis obtusifolia');

    expect(await dedupeTaxa(db, now: nowUtcIso()), 2);
    final kept = await (db.select(
      db.taxa,
    )..where((t) => t.deletedAt.isNull())).getSingle();
    expect(kept.synonyms!.split('; '), hasLength(2));
  });

  test('spelling differences in case and spacing still match', () async {
    await taxon('Rhus  glabra');
    await taxon('rhus glabra', createdAt: '2026-02-01T00:00:00.000Z');
    expect(await dedupeTaxa(db, now: nowUtcIso()), 1);
  });

  test('a clean library is left untouched, and running twice is safe', () async {
    await taxon('Quercus nigra');
    await taxon('Quercus buckleyi');
    expect(await dedupeTaxa(db, now: nowUtcIso()), 0);
    expect(await dedupeTaxa(db, now: nowUtcIso()), 0);
    expect(await living(), ['Quercus buckleyi', 'Quercus nigra']);
  });
}
