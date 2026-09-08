import 'package:drift/drift.dart';

import '../db/database.dart';

/// Propagation lineage across places (D-029). A batch lives where the
/// bench is; its mother plant may grow on another map and its plantings
/// may go to a third. These are the reads every screen shares so the same
/// batch is found from any end of its story.

/// The names on the pickers, in stored order.
const materialTypes = [
  ('seed', 'Seed'),
  ('hardwood_cutting', 'Hardwood cutting'),
  ('softwood_cutting', 'Softwood cutting'),
  ('semi_hardwood_cutting', 'Semi-hardwood cutting'),
  ('sucker', 'Sucker'),
  ('division', 'Division'),
  ('layer', 'Layer'),
  ('transplant', 'Transplant'),
  ('scion', 'Scion'),
];

const propagationMethods = [
  ('water_rooting', 'Water rooting'),
  ('perlite_coir', 'Perlite/coir'),
  ('direct_stick', 'Direct stick'),
  ('flood_tray', 'Flood tray'),
  ('cold_moist_strat', 'Cold moist stratification'),
  ('warm_strat', 'Warm stratification'),
  ('scarification', 'Scarification'),
  ('direct_sow', 'Direct sow'),
  ('other', 'Other'),
];

const stockSources = [
  ('own_propagation', 'Own propagation'),
  ('purchased_container', 'Nursery (container)'),
  ('purchased_bareroot', 'Nursery (bare root)'),
  ('direct_seed', 'Direct seed'),
  ('volunteer', 'Volunteer'),
  ('transplant_onsite', 'Transplant (on site)'),
];

/// The label a picker shows for a stored value.
String labelFor(List<(String, String)> options, String? value) {
  for (final (v, label) in options) {
    if (v == value) return label;
  }
  return (value ?? '').replaceAll('_', ' ');
}

/// What a batch says it did: the blank behind "other" when it was filled,
/// else the method's name.
String methodLabel(PropagationBatche b) {
  if (b.method == 'other' && (b.methodOther ?? '').trim().isNotEmpty) {
    return b.methodOther!.trim();
  }
  return b.method == null
      ? 'method unknown'
      : labelFor(propagationMethods, b.method);
}

/// Where a batch is coming from and going to, with names — one read for
/// the list rows and the lineage rail.
class BatchLineage {
  const BatchLineage({
    required this.batch,
    required this.benchName,
    this.taxon,
    this.collection,
    this.source,
    this.sourcePropertyName,
    this.sourceProperty,
    this.plantings = const [],
    this.plantingPropertyNames = const {},
  });

  final PropagationBatche batch;
  final String benchName;
  final TaxaData? taxon;
  final CollectionEvent? collection;
  final SourcePlant? source;
  final Property? sourceProperty;
  final String? sourcePropertyName;
  final List<PlantingEvent> plantings;

  /// property id → name, for every planting.
  final Map<String, String> plantingPropertyNames;

  String get species =>
      taxon?.commonName ?? taxon?.scientificName ?? 'Unknown species';

  /// The spot the mother plant can be shown at: the record it was found
  /// as, else its own coordinates.
  (double, double)? get sourceSpot {
    final s = source;
    if (s == null || s.lat == null || s.lng == null) return null;
    return (s.lat!, s.lng!);
  }

  /// One line for where the material came from.
  String get originLine {
    final s = source;
    if (s == null) return 'origin not recorded';
    if (s.isOnProperty == 0) {
      return s.originNotes?.trim().isNotEmpty == true
          ? 'ordered · ${s.originNotes!.trim()}'
          : 'ordered';
    }
    return sourcePropertyName ?? 'on property';
  }
}

Future<List<Property>> allProperties(FieldNotesDb db) =>
    (db.select(db.properties)
          ..where((p) => p.deletedAt.isNull())
          ..orderBy([(p) => OrderingTerm.asc(p.name)]))
        .get();

/// Everything about one batch, by id.
Future<BatchLineage?> lineageOf(FieldNotesDb db, String batchId) async {
  final batch = await (db.select(
    db.propagationBatches,
  )..where((b) => b.id.equals(batchId))).getSingleOrNull();
  if (batch == null) return null;
  final all = await lineagesOf(db, [batch]);
  return all.single;
}

/// Lineage for a list of batches with the joins done in bulk.
Future<List<BatchLineage>> lineagesOf(
  FieldNotesDb db,
  List<PropagationBatche> batches,
) async {
  if (batches.isEmpty) return const [];
  final properties = {for (final p in await allProperties(db)) p.id: p};
  final taxonIds = {
    for (final b in batches)
      if (b.taxonId != null) b.taxonId!,
  };
  final taxa = taxonIds.isEmpty
      ? <String, TaxaData>{}
      : {
          for (final t in await (db.select(
            db.taxa,
          )..where((t) => t.id.isIn(taxonIds))).get())
            t.id: t,
        };
  final collectionIds = {
    for (final b in batches)
      if (b.collectionEventId != null) b.collectionEventId!,
  };
  final collections = collectionIds.isEmpty
      ? <String, CollectionEvent>{}
      : {
          for (final c in await (db.select(
            db.collectionEvents,
          )..where((c) => c.id.isIn(collectionIds))).get())
            c.id: c,
        };
  final sourceIds = {
    for (final c in collections.values)
      if (c.sourcePlantId != null) c.sourcePlantId!,
  };
  final sources = sourceIds.isEmpty
      ? <String, SourcePlant>{}
      : {
          for (final s in await (db.select(
            db.sourcePlants,
          )..where((s) => s.id.isIn(sourceIds))).get())
            s.id: s,
        };
  final plantings =
      await (db.select(db.plantingEvents)
            ..where((p) => p.batchId.isIn([for (final b in batches) b.id]))
            ..where((p) => p.deletedAt.isNull())
            ..orderBy([(p) => OrderingTerm.asc(p.plantedOn)]))
          .get();
  final byBatch = <String, List<PlantingEvent>>{};
  for (final p in plantings) {
    (byBatch[p.batchId!] ??= []).add(p);
  }
  return [
    for (final b in batches)
      () {
        final c = collections[b.collectionEventId];
        final s = sources[c?.sourcePlantId];
        final sp = s == null ? null : properties[s.propertyId];
        final ps = byBatch[b.id] ?? const <PlantingEvent>[];
        return BatchLineage(
          batch: b,
          benchName: properties[b.propertyId]?.name ?? 'unknown place',
          taxon: taxa[b.taxonId],
          collection: c,
          source: s,
          sourceProperty: sp,
          sourcePropertyName: sp?.name,
          plantings: ps,
          plantingPropertyNames: {
            for (final p in ps)
              p.propertyId: properties[p.propertyId]?.name ?? 'unknown place',
          },
        );
      }(),
  ];
}

/// The three groups a place's Propagation list shows (D-029, option 1):
/// batches on the bench here, batches whose material was collected here,
/// and batches that were planted out here — the last two only when their
/// bench is elsewhere, so nothing is listed twice.
class GrowGroups {
  const GrowGroups({
    required this.onBench,
    required this.collectedHere,
    required this.plantedHere,
  });
  final List<BatchLineage> onBench;
  final List<BatchLineage> collectedHere;
  final List<BatchLineage> plantedHere;
  bool get isEmpty =>
      onBench.isEmpty && collectedHere.isEmpty && plantedHere.isEmpty;
}

Future<GrowGroups> growGroupsFor(FieldNotesDb db, String propertyId) async {
  final batches =
      await (db.select(db.propagationBatches)
            ..where((b) => b.deletedAt.isNull())
            ..orderBy([(b) => OrderingTerm.desc(b.startedOn)]))
          .get();
  final all = await lineagesOf(db, batches);
  final onBench = <BatchLineage>[];
  final collected = <BatchLineage>[];
  final planted = <BatchLineage>[];
  for (final l in all) {
    if (l.batch.propertyId == propertyId) {
      onBench.add(l);
      continue;
    }
    final fromHere =
        (l.source?.isOnProperty ?? 0) == 1 &&
            l.source?.propertyId == propertyId ||
        l.collection?.propertyId == propertyId;
    if (fromHere) collected.add(l);
    if (l.plantings.any((p) => p.propertyId == propertyId)) planted.add(l);
  }
  return GrowGroups(
    onBench: onBench,
    collectedHere: collected,
    plantedHere: planted,
  );
}

/// The tables the Propagation list follows.
Set<ResultSetImplementation> lineageTables(FieldNotesDb db) => {
  db.propagationBatches,
  db.collectionEvents,
  db.sourcePlants,
  db.plantingEvents,
  db.properties,
  db.taxa,
};

/// Plant a batch out (spec §4.7 → §4.8): the planting carries the lineage
/// link, the batch logs a move with the count that left, and once nothing
/// is left on the bench the batch is planted out. The planting may go to
/// any place — the bench is rarely where the trees end up (D-029).
Future<String> plantOutFromBatch(
  FieldNotesDb db,
  PropagationBatche batch, {
  required String propertyId,
  required int count,
  required String plantedOn,
  String? protection,
  String? notes,
  double? lat,
  double? lng,
}) async {
  final now = nowUtcIso();
  final plantingId = newId();
  await db
      .into(db.plantingEvents)
      .insert(
        PlantingEventsCompanion.insert(
          id: plantingId,
          propertyId: propertyId,
          taxonId: Value(batch.taxonId),
          plantedOn: plantedOn,
          stockSource: 'own_propagation',
          batchId: Value(batch.id),
          countPlanted: count,
          protection: Value(protection),
          lat: Value(lat),
          lng: Value(lng),
          plantingNotes: Value(notes),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ),
      );
  await recordPlantedOut(db, batch, propertyId: propertyId, count: count);
  return plantingId;
}

/// The batch's side of a planting that already exists: a move event and
/// the running count, status planted out when the bench is empty.
Future<void> recordPlantedOut(
  FieldNotesDb db,
  PropagationBatche batch, {
  required String propertyId,
  required int count,
}) async {
  final now = nowUtcIso();
  final place = await (db.select(
    db.properties,
  )..where((p) => p.id.equals(propertyId))).getSingleOrNull();
  final current = batch.countCurrent ?? batch.countStarted ?? count;
  final after = (current - count).clamp(0, 1 << 31);
  await db
      .into(db.batchEvents)
      .insert(
        BatchEventsCompanion.insert(
          id: newId(),
          propertyId: batch.propertyId,
          batchId: batch.id,
          occurredAt: now,
          eventType: 'move',
          countDelta: Value(-count),
          countAfter: Value(after),
          notes: Value('Planted out at ${place?.name ?? 'another place'}'),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ),
      );
  await (db.update(
    db.propagationBatches,
  )..where((b) => b.id.equals(batch.id))).write(
    PropagationBatchesCompanion(
      countCurrent: Value(after),
      status: after == 0 ? const Value('planted_out') : const Value.absent(),
      updatedAt: Value(now),
    ),
  );
}

/// Batches a planting can be linked to: still on a bench somewhere.
Future<List<BatchLineage>> plantableBatches(FieldNotesDb db) async {
  final batches =
      await (db.select(db.propagationBatches)
            ..where((b) => b.deletedAt.isNull())
            ..where(
              (b) =>
                  b.status.isIn(['active', 'rooted', 'hardening']) |
                  b.status.isNull(),
            )
            ..orderBy([(b) => OrderingTerm.desc(b.startedOn)]))
          .get();
  return lineagesOf(db, batches);
}
