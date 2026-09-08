import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/lineage.dart';
import '../../theme/tokens.dart';
import '../../widgets/nativity_chip.dart';
import '../../widgets/press.dart';
import '../../widgets/record_picker.dart';
import '../../widgets/species_field.dart';
import 'batch_detail_screen.dart';

/// Propagation (spec §7.6, D-029): a batch lives where the bench is, and
/// this list reads from wherever you stand — the batches on the bench
/// here, the ones whose material was collected here, and the ones that
/// went into the ground here.
class PropagationScreen extends StatelessWidget {
  const PropagationScreen({
    super.key,
    required this.db,
    required this.property,
    this.embedded = false,
  });

  final FieldNotesDb db;
  final Property property;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: embedded ? null : AppBar(title: const Text('Propagation')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New batch'),
        onPressed: () => _newBatch(context),
      ),
      body: StreamBuilder<GrowGroups>(
        stream: db
            .changes(lineageTables(db))
            .asyncMap((_) => growGroupsFor(db, property.id)),
        builder: (context, snapshot) {
          final g = snapshot.data;
          if (g == null) return const SizedBox.shrink();
          if (g.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'No batches on the bench yet. Start one from seed or '
                  'cuttings and its whole story — where it came from to '
                  'where it went — collects here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: Type.serif,
                    fontSize: 15,
                    height: 1.5,
                    color: Press.inkSoft,
                  ),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 140),
            children: [
              _section(
                'On the bench here',
                g.onBench,
                empty: 'Nothing on a bench at ${property.name}.',
                line: (l) => null,
              ),
              if (g.collectedHere.isNotEmpty)
                _section(
                  'Collected from here',
                  g.collectedHere,
                  line: (l) => 'bench · ${l.benchName}',
                ),
              if (g.plantedHere.isNotEmpty)
                _section(
                  'Planted out here',
                  g.plantedHere,
                  line: (l) => 'bench · ${l.benchName}',
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _section(
    String title,
    List<BatchLineage> rows, {
    String? empty,
    required String? Function(BatchLineage) line,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(Metrics.gutter, 16, Metrics.gutter, 4),
          child: MonoLabel(title.toUpperCase(), size: 9.5, spacing: 2),
        ),
        if (rows.isEmpty && empty != null)
          Padding(
            padding: EdgeInsets.fromLTRB(Metrics.gutter, 8, Metrics.gutter, 8),
            child: Text(
              empty,
              style: TextStyle(fontFamily: Type.serif, color: Press.inkSoft),
            ),
          ),
        for (final l in rows) _BatchTile(db: db, lineage: l, extra: line(l)),
      ],
    );
  }

  Future<void> _newBatch(BuildContext context) async {
    final places = await allProperties(db);
    if (!context.mounted) return;
    TaxaData? taxon;
    var method = 'perlite_coir';
    var material = 'hardwood_cutting';
    // Where the material came from: one of the places, or ordered.
    String? originId = property.id;
    PickedRecord? record;
    final codeController = TextEditingController();
    final countController = TextEditingController();
    final containerController = TextEditingController();
    final mixController = TextEditingController();
    final methodOtherController = TextEditingController();
    final sourceLabelController = TextEditingController();
    final vendorController = TextEditingController();

    // Validated inside the sheet (audit M12): a batch needs at least a
    // species or a code, or it can never be found again.
    bool valid() => taxon != null || codeController.text.trim().isNotEmpty;

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(
                'New propagation batch',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              MonoLabel(
                'bench · ${property.name}',
                size: 9,
                spacing: 1.5,
                opacity: 0.7,
              ),
              const SizedBox(height: 12),
              SpeciesField(
                db: db,
                label: 'Species',
                onSelected: (t) => setSheet(() => taxon = t),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: codeController,
                onChanged: (_) => setSheet(() {}),
                decoration: InputDecoration(
                  labelText: 'Batch code (e.g. M-07)',
                  helperText: valid() ? null : 'Give it a species or a code',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: countController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Count started',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: method,
                decoration: const InputDecoration(
                  labelText: 'Method',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final (v, label) in propagationMethods)
                    DropdownMenuItem(value: v, child: Text(label)),
                ],
                onChanged: (v) => setSheet(() => method = v ?? method),
              ),
              if (method == 'other') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: methodOtherController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Which method?',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: containerController,
                decoration: const InputDecoration(
                  labelText: 'Container (e.g. Stuewe D40)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: mixController,
                decoration: const InputDecoration(
                  labelText: 'Soil mix (e.g. 50/50 perlite and coir)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              MonoLabel('WHERE THE MATERIAL CAME FROM', size: 9.5, spacing: 2),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: material,
                decoration: const InputDecoration(
                  labelText: 'Material',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final (v, label) in materialTypes)
                    DropdownMenuItem(value: v, child: Text(label)),
                ],
                onChanged: (v) => material = v ?? material,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: originId,
                decoration: const InputDecoration(
                  labelText: 'From',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final p in places)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Ordered / nursery'),
                  ),
                ],
                onChanged: (v) => setSheet(() {
                  originId = v;
                  record = null;
                }),
              ),
              const SizedBox(height: 12),
              if (originId == null)
                TextField(
                  controller: vendorController,
                  decoration: const InputDecoration(
                    labelText: 'Vendor (e.g. Sheffield\'s Seed Co)',
                    border: OutlineInputBorder(),
                  ),
                )
              else ...[
                TextField(
                  controller: sourceLabelController,
                  decoration: const InputDecoration(
                    labelText: 'Mother plant (e.g. Riverbank willow #3)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                // The link back to the ground: the record you found it as.
                Row(
                  children: [
                    Expanded(
                      child: record == null
                          ? MonoLabel(
                              'no record linked',
                              size: 9.5,
                              opacity: 0.6,
                            )
                          : MonoLabel(
                              'record · ${record!.label}',
                              size: 9.5,
                              color: Press.ink,
                            ),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.place_outlined, size: 18),
                      label: Text(record == null ? 'LINK A RECORD' : 'CHANGE'),
                      onPressed: () async {
                        final picked = await showRecordPicker(
                          context,
                          db: db,
                          propertyId: originId!,
                          taxonId: taxon?.id,
                        );
                        if (picked != null) setSheet(() => record = picked);
                      },
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                height: 56,
                child: FilledButton(
                  onPressed: valid()
                      ? () => Navigator.pop(context, true)
                      : null,
                  child: const Text('Start batch'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (created != true || !valid()) return;
    final now = nowUtcIso();
    final today = now.substring(0, 10);
    final count = int.tryParse(countController.text.trim());
    final species = taxon?.commonName ?? taxon?.scientificName;

    // Lineage chain: source plant → collection event → batch (spec §4.7).
    // The mother plant is filed where it grows (D-029); ordered material
    // is filed on the bench, marked offsite, with the vendor as its origin.
    final origin = originId == null
        ? null
        : places.firstWhere((p) => p.id == originId);
    final ordered = origin == null;
    final label = ordered
        ? (vendorController.text.trim().isEmpty
              ? 'Ordered'
              : vendorController.text.trim())
        : (sourceLabelController.text.trim().isEmpty
              ? '${species ?? 'Mother plant'} · ${origin.name}'
              : sourceLabelController.text.trim());
    final sourcePlantId = newId();
    await db
        .into(db.sourcePlants)
        .insert(
          SourcePlantsCompanion.insert(
            id: sourcePlantId,
            propertyId: origin?.id ?? property.id,
            taxonId: Value(taxon?.id),
            label: label,
            lat: Value(record?.lat),
            lng: Value(record?.lng),
            isOnProperty: Value(ordered ? 0 : 1),
            originNotes: Value(
              ordered && vendorController.text.trim().isNotEmpty
                  ? vendorController.text.trim()
                  : null,
            ),
            observationId: Value(record?.id),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final collectionEventId = newId();
    await db
        .into(db.collectionEvents)
        .insert(
          CollectionEventsCompanion.insert(
            id: collectionEventId,
            propertyId: origin?.id ?? property.id,
            sourcePlantId: Value(sourcePlantId),
            collectedOn: today,
            materialType: material,
            quantity: Value(count),
            lat: Value(record?.lat),
            lng: Value(record?.lng),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );

    String? text(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    await db
        .into(db.propagationBatches)
        .insert(
          PropagationBatchesCompanion.insert(
            id: newId(),
            propertyId: property.id,
            collectionEventId: Value(collectionEventId),
            taxonId: Value(taxon?.id),
            batchCode: Value(text(codeController)),
            startedOn: today,
            method: Value(method),
            methodOther: Value(
              method == 'other' ? text(methodOtherController) : null,
            ),
            container: Value(text(containerController)),
            medium: Value(text(mixController)),
            countStarted: Value(count),
            countCurrent: Value(count),
            status: const Value('active'),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
  }
}

class _BatchTile extends StatelessWidget {
  const _BatchTile({required this.db, required this.lineage, this.extra});

  final FieldNotesDb db;
  final BatchLineage lineage;

  /// A second line for a batch listed away from its bench.
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final batch = lineage.batch;
    final t = lineage.taxon;
    return ListTile(
      minTileHeight: 64,
      leading: CircleAvatar(
        child: Text(batch.batchCode?.substring(0, 1) ?? 'B'),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              '${batch.batchCode != null ? '${batch.batchCode} · ' : ''}'
              '${lineage.species}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (t?.nativity != null) ...[
            const SizedBox(width: 8),
            NativityChip(t!.nativity),
          ],
        ],
      ),
      subtitle: Text(
        '${batch.status ?? 'active'} · '
        '${batch.countCurrent ?? batch.countStarted ?? '?'} of '
        '${batch.countStarted ?? '?'} · started ${batch.startedOn}'
        '${extra != null ? '\n$extra' : ''}',
      ),
      isThreeLine: extra != null,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BatchDetailScreen(db: db, batchId: batch.id),
        ),
      ),
    );
  }
}
