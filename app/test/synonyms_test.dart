import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/seed.dart';
import 'package:field_notes/db/seed_synonyms.dart';
import 'package:field_notes/id/id_models.dart';
import 'package:field_notes/id/identification_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-032: a species answers to its other names.
void main() {
  late FieldNotesDb db;
  setUp(() => db = FieldNotesDb.forTesting());
  tearDown(() => db.close());

  Future<TaxaData> taxon(
    String name, {
    String? synonyms,
    String? propertyId,
  }) async {
    final now = nowUtcIso();
    return db
        .into(db.taxa)
        .insertReturning(
          TaxaCompanion.insert(
            id: newId(),
            scientificName: name,
            propertyId: Value(propertyId),
            synonyms: Value(synonyms),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  test(
    'the seed carries synonyms, and the laurel is filed under its current name',
    () async {
      final n = await seedTaxaIfEmpty(
        db,
        csvText: File('assets/seed/taxa_seed.csv').readAsStringSync(),
      );
      expect(n, greaterThan(100));
      final laurel =
          await (db.select(db.taxa)..where(
                (t) => t.scientificName.equals('Dermatophyllum secundiflorum'),
              ))
              .getSingle();
      expect(laurel.synonyms, contains('Sophora secundiflora'));
      expect(laurel.nativity, 'native');
      final sycamore =
          await (db.select(db.taxa)..where(
                (t) => t.scientificName.equals(
                  'Platanus occidentalis var. glabrata',
                ),
              ))
              .getSingle();
      expect(splitSynonyms(sycamore.synonyms), ['Platanus occidentalis']);
    },
  );

  test('an older library is served synonyms in both directions', () async {
    final old = await taxon('Sophora secundiflora'); // filed under the old name
    final current = await taxon(
      'Bouteloua dactyloides',
    ); // filed under the new one
    final mine = await taxon(
      'Quercus fusiformis',
      synonyms: 'my own note',
    ); // left alone
    final touched = await applySeedSynonyms(db);
    expect(touched, 2);
    final rows = {for (final t in await db.select(db.taxa).get()) t.id: t};
    expect(splitSynonyms(rows[old.id]!.synonyms), [
      'Dermatophyllum secundiflorum',
      'Calia secundiflora',
    ]);
    expect(splitSynonyms(rows[current.id]!.synonyms), ['Buchloe dactyloides']);
    expect(rows[mine.id]!.synonyms, 'my own note');
    expect(await applySeedSynonyms(db), 0, reason: 'safe to repeat');
  });

  test(
    'identification finds the row by a synonym, the property\'s own row first',
    () async {
      final shared = await taxon(
        'Dermatophyllum secundiflorum',
        synonyms: 'Sophora secundiflora; Calia secundiflora',
      );
      final theirs = await taxon('Sophora secundiflora', propertyId: 'p1');
      final svc = IdentificationService(db);
      final out = await svc.matchToLibrary([
        IdCandidate(
          name: 'sophora secundiflora',
          score: 0.9,
          source: 'plantnet',
        ),
        IdCandidate(name: 'Calia secundiflora', score: 0.5, source: 'llm'),
        IdCandidate(name: 'Quercus nobody', score: 0.1, source: 'llm'),
      ], 'p1');
      expect(
        out[0].taxonId,
        theirs.id,
        reason: 'the property\'s own entry wins',
      );
      expect(
        out[1].taxonId,
        shared.id,
        reason: 'a synonym reaches the shared row',
      );
      expect(out[2].taxonId, isNull);
      final elsewhere = await svc.matchToLibrary([
        IdCandidate(
          name: 'Sophora secundiflora',
          score: 0.9,
          source: 'plantnet',
        ),
      ], 'p2');
      expect(
        elsewhere.single.taxonId,
        shared.id,
        reason: 'p1\'s private row is not p2\'s',
      );
    },
  );
}
