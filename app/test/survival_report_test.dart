import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/export/survival_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FieldNotesDb db;
  late Property property;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    final now = nowUtcIso();
    final propId = newId();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
          id: propId,
          name: 'Shorts Resort',
          createdBy: 'a',
          createdAt: now,
          updatedAt: now,
        ));
    property = await (db.select(db.properties)
          ..where((p) => p.id.equals(propId)))
        .getSingle();
    final taxonId = newId();
    await db.into(db.taxa).insert(TaxaCompanion.insert(
          id: taxonId,
          scientificName: 'Salix nigra',
          commonName: const Value('Black Willow'),
          createdAt: now,
          updatedAt: now,
        ));
    final eventId = newId();
    await db.into(db.plantingEvents).insert(PlantingEventsCompanion.insert(
          id: eventId,
          propertyId: propId,
          taxonId: Value(taxonId),
          plantedOn: '2025-12-14',
          stockSource: 'own_propagation',
          countPlanted: 40,
          createdBy: 'a',
          createdAt: now,
          updatedAt: now,
        ));
    await db.into(db.plantCheckins).insert(PlantCheckinsCompanion.insert(
          id: newId(),
          propertyId: propId,
          plantingEventId: Value(eventId),
          checkedAt: '2026-03-20T12:00:00Z',
          status: 'alive',
          countAlive: const Value(31),
          countDead: const Value(9),
          createdBy: 'a',
          createdAt: now,
          updatedAt: now,
        ));
  });

  tearDown(() => db.close());

  test('builds a PDF with the cohort survival figure', () async {
    final bytes = await SurvivalReport(db).build(property);
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.sublist(0, 4)), '%PDF');
  });

  test('empty property still produces a document', () async {
    final now = nowUtcIso();
    final id = newId();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
        id: id, name: 'Empty', createdBy: 'a', createdAt: now, updatedAt: now));
    final empty = await (db.select(db.properties)..where((p) => p.id.equals(id)))
        .getSingle();
    final bytes = await SurvivalReport(db).build(empty);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), '%PDF');
  });
}
