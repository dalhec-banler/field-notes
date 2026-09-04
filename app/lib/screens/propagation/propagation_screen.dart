import 'package:drift/drift.dart' hide Column;

import '../../theme/tokens.dart';

import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../widgets/species_field.dart';
import 'batch_detail_screen.dart';

/// Propagation (spec §7.6): batches with counts and status.
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
    final query = (db.select(db.propagationBatches)
      ..where((b) => b.propertyId.equals(property.id))
      ..where((b) => b.deletedAt.isNull())
      ..orderBy([(b) => OrderingTerm.desc(b.startedOn)]));
    return Scaffold(
      appBar: embedded ? null : AppBar(title: const Text('Propagation')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New batch'),
        onPressed: () => _newBatch(context),
      ),
      body: StreamBuilder<List<PropagationBatche>>(
        stream: query.watch(),
        builder: (context, snapshot) {
          final batches = snapshot.data ?? const [];
          if (batches.isEmpty) {
            return Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'No batches on the bench yet. Start one from seed or '
                  'cuttings and its whole story — sowing to planting out — '
                  'collects here.',
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
          return ListView.builder(
            padding: EdgeInsets.only(bottom: 140),
            itemCount: batches.length,
            itemBuilder: (context, i) => _BatchTile(db: db, batch: batches[i]),
          );
        },
      ),
    );
  }

  Future<void> _newBatch(BuildContext context) async {
    TaxaData? taxon;
    var method = 'perlite_coir';
    final codeController = TextEditingController();
    final countController = TextEditingController();
    final containerController = TextEditingController();
    final sourceLabelController = TextEditingController();

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
                items: const [
                  DropdownMenuItem(
                    value: 'water_rooting',
                    child: Text('Water rooting'),
                  ),
                  DropdownMenuItem(
                    value: 'perlite_coir',
                    child: Text('Perlite/coir'),
                  ),
                  DropdownMenuItem(
                    value: 'direct_stick',
                    child: Text('Direct stick'),
                  ),
                  DropdownMenuItem(
                    value: 'flood_tray',
                    child: Text('Flood tray'),
                  ),
                  DropdownMenuItem(
                    value: 'cold_moist_strat',
                    child: Text('Cold moist stratification'),
                  ),
                  DropdownMenuItem(
                    value: 'warm_strat',
                    child: Text('Warm stratification'),
                  ),
                  DropdownMenuItem(
                    value: 'scarification',
                    child: Text('Scarification'),
                  ),
                  DropdownMenuItem(
                    value: 'direct_sow',
                    child: Text('Direct sow'),
                  ),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => method = v ?? method,
              ),
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
                controller: sourceLabelController,
                decoration: const InputDecoration(
                  labelText:
                      'Mother plant (optional, e.g. Riverbank willow #3)',
                  helperText:
                      'Creates the source plant + collection event for lineage',
                  border: OutlineInputBorder(),
                ),
              ),
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

    // Lineage chain: source plant → collection event → batch (spec §4.7).
    String? collectionEventId;
    final sourceLabel = sourceLabelController.text.trim();
    if (sourceLabel.isNotEmpty) {
      final sourcePlantId = newId();
      await db
          .into(db.sourcePlants)
          .insert(
            SourcePlantsCompanion.insert(
              id: sourcePlantId,
              propertyId: property.id,
              taxonId: Value(taxon?.id),
              label: sourceLabel,
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
      collectionEventId = newId();
      await db
          .into(db.collectionEvents)
          .insert(
            CollectionEventsCompanion.insert(
              id: collectionEventId,
              propertyId: property.id,
              sourcePlantId: Value(sourcePlantId),
              collectedOn: today,
              materialType: 'hardwood_cutting',
              quantity: Value(count),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }

    await db
        .into(db.propagationBatches)
        .insert(
          PropagationBatchesCompanion.insert(
            id: newId(),
            propertyId: property.id,
            collectionEventId: Value(collectionEventId),
            taxonId: Value(taxon?.id),
            batchCode: Value(
              codeController.text.trim().isEmpty
                  ? null
                  : codeController.text.trim(),
            ),
            startedOn: today,
            method: Value(method),
            container: Value(
              containerController.text.trim().isEmpty
                  ? null
                  : containerController.text.trim(),
            ),
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
  const _BatchTile({required this.db, required this.batch});

  final FieldNotesDb db;
  final PropagationBatche batch;

  Future<String> _species() async {
    if (batch.taxonId == null) return 'Unknown species';
    final t = await (db.select(
      db.taxa,
    )..where((x) => x.id.equals(batch.taxonId!))).getSingleOrNull();
    return t?.commonName ?? t?.scientificName ?? 'Unknown species';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _species(),
      builder: (context, snapshot) {
        final species = snapshot.data ?? '…';
        return ListTile(
          minTileHeight: 64,
          leading: CircleAvatar(
            child: Text(batch.batchCode?.substring(0, 1) ?? 'B'),
          ),
          title: Text(
            '${batch.batchCode != null ? '${batch.batchCode} · ' : ''}$species',
          ),
          subtitle: Text(
            '${batch.status ?? 'active'} · '
            '${batch.countCurrent ?? batch.countStarted ?? '?'} of '
            '${batch.countStarted ?? '?'} · started ${batch.startedOn}',
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => BatchDetailScreen(db: db, batchId: batch.id),
            ),
          ),
        );
      },
    );
  }
}
