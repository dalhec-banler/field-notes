import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/lineage.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-029: a batch lives where the bench is, and its story reads from
/// every place it touches.
void main() {
  late FieldNotesDb db;
  late String bench, lake, shorts;

  Future<String> place(String name, {String tenure = 'owned'}) async {
    final now = nowUtcIso();
    final id = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: id,
            name: name,
            landTenure: Value(tenure),
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return id;
  }

  /// A batch on [bench] with material collected on [from] (null = ordered).
  Future<PropagationBatche> batch({
    String? from,
    int count = 10,
    String code = 'B-1',
  }) async {
    final now = nowUtcIso();
    final sourceId = newId();
    await db
        .into(db.sourcePlants)
        .insert(
          SourcePlantsCompanion.insert(
            id: sourceId,
            propertyId: from ?? bench,
            label: from == null ? 'Sheffield\'s' : 'Willow #3',
            isOnProperty: Value(from == null ? 0 : 1),
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final collectionId = newId();
    await db
        .into(db.collectionEvents)
        .insert(
          CollectionEventsCompanion.insert(
            id: collectionId,
            propertyId: from ?? bench,
            sourcePlantId: Value(sourceId),
            collectedOn: '2026-09-01',
            materialType: from == null ? 'seed' : 'hardwood_cutting',
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final id = newId();
    await db
        .into(db.propagationBatches)
        .insert(
          PropagationBatchesCompanion.insert(
            id: id,
            propertyId: bench,
            collectionEventId: Value(collectionId),
            batchCode: Value(code),
            startedOn: '2026-09-02',
            method: const Value('other'),
            methodOther: const Value('sand bed under mist'),
            countStarted: Value(count),
            countCurrent: Value(count),
            status: const Value('active'),
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return (db.select(
      db.propagationBatches,
    )..where((b) => b.id.equals(id))).getSingle();
  }

  setUp(() async {
    db = FieldNotesDb.forTesting();
    bench = await place('Arapahouse');
    lake = await place('Lake Side', tenure: 'collection_site');
    shorts = await place('Shorts');
  });
  tearDown(() => db.close());

  test(
    'one batch shows on the bench, at its source, and where it went',
    () async {
      final b = await batch(from: lake);
      await plantOutFromBatch(
        db,
        b,
        propertyId: shorts,
        count: 4,
        plantedOn: '2026-09-08',
      );

      final atBench = await growGroupsFor(db, bench);
      expect(atBench.onBench.map((l) => l.batch.id), [b.id]);
      expect(atBench.collectedHere, isEmpty);
      expect(atBench.plantedHere, isEmpty);

      final atLake = await growGroupsFor(db, lake);
      expect(atLake.onBench, isEmpty);
      expect(atLake.collectedHere.map((l) => l.batch.id), [b.id]);
      expect(atLake.collectedHere.single.benchName, 'Arapahouse');
      expect(atLake.plantedHere, isEmpty);

      final atShorts = await growGroupsFor(db, shorts);
      expect(atShorts.onBench, isEmpty);
      expect(atShorts.collectedHere, isEmpty);
      expect(atShorts.plantedHere.map((l) => l.batch.id), [b.id]);
      expect(
        atShorts.plantedHere.single.plantingPropertyNames[shorts],
        'Shorts',
      );
    },
  );

  test('ordered material is not "collected from" the bench', () async {
    await batch(from: null);
    final atBench = await growGroupsFor(db, bench);
    expect(atBench.onBench, hasLength(1));
    expect(atBench.collectedHere, isEmpty);
    expect(atBench.onBench.single.originLine, startsWith('ordered'));
  });

  test(
    'planting out takes the count off the bench and closes it at zero',
    () async {
      final b = await batch(count: 10);
      await plantOutFromBatch(
        db,
        b,
        propertyId: shorts,
        count: 6,
        plantedOn: '2026-09-08',
      );
      var now = await (db.select(
        db.propagationBatches,
      )..where((x) => x.id.equals(b.id))).getSingle();
      expect(now.countCurrent, 4);
      expect(now.status, 'active');
      final events = await (db.select(
        db.batchEvents,
      )..where((e) => e.batchId.equals(b.id))).get();
      expect(events.single.eventType, 'move');
      expect(events.single.countDelta, -6);
      expect(events.single.notes, contains('Shorts'));

      await recordPlantedOut(db, now, propertyId: shorts, count: 4);
      now = await (db.select(
        db.propagationBatches,
      )..where((x) => x.id.equals(b.id))).getSingle();
      expect(now.countCurrent, 0);
      expect(now.status, 'planted_out');

      final plantings = await (db.select(
        db.plantingEvents,
      )..where((p) => p.batchId.equals(b.id))).get();
      expect(plantings.single.propertyId, shorts);
      expect(plantings.single.stockSource, 'own_propagation');
      expect(await plantableBatches(db), isEmpty);
    },
  );

  test('the blank behind "other" is what the batch says it did', () async {
    final b = await batch();
    expect(methodLabel(b), 'sand bed under mist');
    expect(
      labelFor(stockSources, 'purchased_container'),
      'Nursery (container)',
    );
  });
}
