import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../widgets/edit_sheet.dart';

/// Add one species by hand — the plant you know is here and the library
/// does not: name, common name, what kind of plant, native or not. Starred
/// so it lands in the quick pick.
Future<TaxaData?> showAddSpeciesSheet(
  BuildContext context, {
  required FieldNotesDb db,
  required Property property,
  String? initialName,
}) async {
  final result = await showEditSheet(
    context,
    title: 'ADD A SPECIES',
    fields: [
      TextEdit('scientific', 'Scientific name', initial: initialName),
      TextEdit('common', 'Common name'),
      ChoiceEdit(
        'growth',
        'Kind of plant',
        allowNone: true,
        options: const [
          ('tree', 'Tree'),
          ('shrub', 'Shrub'),
          ('graminoid', 'Grass or sedge'),
          ('forb', 'Wildflower or weed'),
          ('vine', 'Vine'),
          ('succulent', 'Succulent'),
          ('fern', 'Fern'),
          ('other', 'Other'),
        ],
      ),
      ChoiceEdit(
        'nativity',
        'Native here?',
        allowNone: true,
        options: const [
          ('native', 'Native'),
          ('introduced', 'Introduced'),
          ('invasive', 'Invasive'),
          ('cultivated', 'Planted, not wild'),
          ('unknown', 'Not sure'),
        ],
      ),
    ],
  );
  if (result == null) return null;
  final sci = result.text('scientific')?.trim();
  if (sci == null || sci.isEmpty) return null;
  final now = nowUtcIso();
  final id = newId();
  await db
      .into(db.taxa)
      .insert(
        TaxaCompanion.insert(
          id: id,
          propertyId: Value(property.id),
          scientificName: sci,
          commonName: Value(result.text('common')?.trim()),
          growthForm: Value(result.text('growth')),
          nativity: Value(result.text('nativity')),
          isFavorite: const Value(1),
          createdBy: const Value('local'),
          createdAt: now,
          updatedAt: now,
        ),
      );
  return (db.select(db.taxa)..where((t) => t.id.equals(id))).getSingle();
}
