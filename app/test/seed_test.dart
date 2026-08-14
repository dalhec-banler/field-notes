import 'dart:io';

import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/seed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FieldNotesDb db;
  late String csvText;

  setUpAll(() {
    csvText = File('assets/seed/taxa_seed.csv').readAsStringSync();
  });

  setUp(() => db = FieldNotesDb.forTesting());
  tearDown(() => db.close());

  test('seeds the full library with favorites marked', () async {
    final inserted = await seedTaxaIfEmpty(db, csvText: csvText);
    expect(inserted, 179);

    final favorites = await (db.select(db.taxa)
          ..where((t) => t.isFavorite.equals(1)))
        .get();
    expect(favorites.length, 56);

    final willow = await (db.select(db.taxa)
          ..where((t) => t.scientificName.equals('Salix nigra')))
        .getSingle();
    expect(willow.isFavorite, 1);
    expect(willow.propertyId, isNull);
  });

  test('is idempotent — second run inserts nothing', () async {
    await seedTaxaIfEmpty(db, csvText: csvText);
    final second = await seedTaxaIfEmpty(db, csvText: csvText);
    expect(second, 0);
  });

  test('all seed rows satisfy the CHECK constraints', () async {
    // Insert would have thrown on any invalid growth_form/nativity value;
    // spot-check the enum domains actually present.
    await seedTaxaIfEmpty(db, csvText: csvText);
    final all = await db.select(db.taxa).get();
    const forms = {
      'tree', 'shrub', 'forb', 'graminoid', 'vine', 'succulent',
      'fern', 'moss', 'other'
    };
    const nativities = {
      'native', 'introduced', 'invasive', 'cultivated', 'unknown'
    };
    for (final t in all) {
      if (t.growthForm != null) expect(forms, contains(t.growthForm));
      if (t.nativity != null) expect(nativities, contains(t.nativity));
    }
  });
}
