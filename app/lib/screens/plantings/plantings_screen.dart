import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/survival.dart';
import '../../theme/tokens.dart';
import '../../widgets/press.dart';
import '../../widgets/species_field.dart';
import 'planting_detail_screen.dart';

/// Plantings (spec §7.5): events with survival %, drill into cohorts.
class PlantingsScreen extends StatelessWidget {
  const PlantingsScreen(
      {super.key,
      required this.db,
      required this.property,
      this.embedded = false});

  final FieldNotesDb db;
  final Property property;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final query = (db.select(db.plantingEvents)
      ..where((e) => e.propertyId.equals(property.id))
      ..where((e) => e.deletedAt.isNull())
      ..orderBy([(e) => OrderingTerm.desc(e.plantedOn)]));
    return Scaffold(
      appBar: embedded ? null : AppBar(title: const Text('Plantings')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New planting'),
        onPressed: () => _newPlanting(context),
      ),
      body: StreamBuilder<List<PlantingEvent>>(
        stream: query.watch(),
        builder: (context, snapshot) {
          final events = snapshot.data ?? const [];
          if (events.isEmpty) {
            return const Center(
                child: Text('No plantings recorded yet.'));
          }
          return ListView.builder(
            itemCount: events.length,
            itemBuilder: (context, i) =>
                _PlantingTile(db: db, event: events[i]),
          );
        },
      ),
    );
  }

  Future<void> _newPlanting(BuildContext context) async {
    TaxaData? taxon;
    var stockSource = 'own_propagation';
    var protection = 'welded_wire_cage';
    var plantedOn = DateTime.now();
    final countController = TextEditingController();
    final notesController = TextEditingController();

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
              Text('New planting',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              SpeciesField(
                  db: db, label: 'Species', onSelected: (t) => taxon = t),
              const SizedBox(height: 12),
              TextField(
                controller: countController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Count planted',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: stockSource,
                decoration: const InputDecoration(
                    labelText: 'Stock source', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(
                      value: 'own_propagation',
                      child: Text('Own propagation')),
                  DropdownMenuItem(
                      value: 'purchased_container',
                      child: Text('Purchased container')),
                  DropdownMenuItem(
                      value: 'purchased_bareroot',
                      child: Text('Purchased bareroot')),
                  DropdownMenuItem(
                      value: 'direct_seed', child: Text('Direct seed')),
                  DropdownMenuItem(
                      value: 'volunteer', child: Text('Volunteer')),
                  DropdownMenuItem(
                      value: 'transplant_onsite',
                      child: Text('Transplant on-site')),
                ],
                onChanged: (v) => stockSource = v ?? stockSource,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: protection,
                decoration: const InputDecoration(
                    labelText: 'Protection', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('None')),
                  DropdownMenuItem(
                      value: 'welded_wire_cage',
                      child: Text('Welded wire cage')),
                  DropdownMenuItem(
                      value: 'tree_tube', child: Text('Tree tube')),
                  DropdownMenuItem(value: 'fencing', child: Text('Fencing')),
                  DropdownMenuItem(
                      value: 'mulch_only', child: Text('Mulch only')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => protection = v ?? protection,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text('Planted on '
                    '${plantedOn.toIso8601String().substring(0, 10)}'),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: plantedOn,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setSheet(() => plantedOn = picked);
                },
              ),
              TextField(
                controller: notesController,
                decoration: const InputDecoration(
                    labelText: 'Notes', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 56,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Save planting'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (created != true) return;
    final count = int.tryParse(countController.text.trim());
    if (count == null || count <= 0) return;
    final now = nowUtcIso();
    await db.into(db.plantingEvents).insert(PlantingEventsCompanion.insert(
          id: newId(),
          propertyId: property.id,
          taxonId: Value(taxon?.id),
          plantedOn: plantedOn.toIso8601String().substring(0, 10),
          stockSource: stockSource,
          countPlanted: count,
          protection: Value(protection),
          plantingNotes: Value(notesController.text.trim().isEmpty
              ? null
              : notesController.text.trim()),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
  }
}

class _PlantingTile extends StatelessWidget {
  const _PlantingTile({required this.db, required this.event});

  final FieldNotesDb db;
  final PlantingEvent event;

  Future<(String, SurvivalResult?)> _load() async {
    var species = 'Unknown species';
    if (event.taxonId != null) {
      final t = await (db.select(db.taxa)
            ..where((x) => x.id.equals(event.taxonId!)))
          .getSingleOrNull();
      species = t?.scientificName ?? t?.commonName ?? species;
    }
    return (species, await survivalFor(db, event));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(String, SurvivalResult?)>(
      future: _load(),
      builder: (context, snapshot) {
        final (species, survival) = snapshot.data ?? ('…', null);
        final band =
            survival == null ? Press.inkSoft : survivalBandColor(survival.rate);
        return InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlantingDetailScreen(db: db, eventId: event.id),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: Metrics.gutter, vertical: 13),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Press.divider, width: 1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: TaxonName(species, size: 20, maxLines: 1)),
                    const SizedBox(width: 10),
                    survival == null
                        ? const MonoLabel('no check-ins',
                            size: 9, opacity: 0.6)
                        : Text(
                            '${(survival.rate * 100).toStringAsFixed(0)}%',
                            style: TextStyle(
                              fontFamily: Type.slab,
                              fontWeight: FontWeight.w900,
                              fontSize: 20,
                              height: 1,
                              color: band,
                            ),
                          ),
                  ],
                ),
                const SizedBox(height: 5),
                MonoLabel(
                  '${event.plantedOn} · ${event.stockSource.replaceAll('_', ' ')}'
                  '${event.protection != null ? ' · ${event.protection!.replaceAll('_', ' ')}' : ''}',
                  size: 9,
                  opacity: 0.72,
                ),
                if (survival != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 9,
                          decoration: BoxDecoration(
                            color: const Color(0x121B1813),
                            border: Border.all(color: Press.ink, width: 1),
                          ),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: survival.rate.clamp(0.0, 1.0),
                            child: Container(color: band),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      MonoLabel('${survival.alive} / ${survival.total}',
                          size: 9, opacity: 0.8),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
