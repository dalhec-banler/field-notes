import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';

/// Batch detail (spec §7.6): event log, status, counts, and the lineage view
/// from mother plant → collection → batch → plantings.
class BatchDetailScreen extends StatefulWidget {
  const BatchDetailScreen(
      {super.key, required this.db, required this.batchId});

  final FieldNotesDb db;
  final String batchId;

  @override
  State<BatchDetailScreen> createState() => _BatchDetailScreenState();
}

class _BatchDetailScreenState extends State<BatchDetailScreen> {
  PropagationBatche? _batch;
  TaxaData? _taxon;
  CollectionEvent? _collection;
  SourcePlant? _sourcePlant;
  List<BatchEvent> _events = const [];
  List<PlantingEvent> _plantings = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.db;
    final batch = await (db.select(db.propagationBatches)
          ..where((b) => b.id.equals(widget.batchId)))
        .getSingleOrNull();
    if (batch == null) return;
    TaxaData? taxon;
    if (batch.taxonId != null) {
      taxon = await (db.select(db.taxa)
            ..where((t) => t.id.equals(batch.taxonId!)))
          .getSingleOrNull();
    }
    CollectionEvent? collection;
    SourcePlant? sourcePlant;
    if (batch.collectionEventId != null) {
      collection = await (db.select(db.collectionEvents)
            ..where((c) => c.id.equals(batch.collectionEventId!)))
          .getSingleOrNull();
      if (collection?.sourcePlantId != null) {
        sourcePlant = await (db.select(db.sourcePlants)
              ..where((s) => s.id.equals(collection!.sourcePlantId!)))
            .getSingleOrNull();
      }
    }
    final events = await (db.select(db.batchEvents)
          ..where((e) => e.batchId.equals(batch.id))
          ..where((e) => e.deletedAt.isNull())
          ..orderBy([(e) => OrderingTerm.desc(e.occurredAt)]))
        .get();
    final plantings = await (db.select(db.plantingEvents)
          ..where((p) => p.batchId.equals(batch.id))
          ..where((p) => p.deletedAt.isNull()))
        .get();
    if (mounted) {
      setState(() {
        _batch = batch;
        _taxon = taxon;
        _collection = collection;
        _sourcePlant = sourcePlant;
        _events = events;
        _plantings = plantings;
      });
    }
  }

  Future<void> _addEvent() async {
    final batch = _batch!;
    var eventType = 'check';
    final deltaController = TextEditingController();
    final notesController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Log batch event'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: eventType,
                decoration: const InputDecoration(labelText: 'Event'),
                items: const [
                  DropdownMenuItem(value: 'check', child: Text('Check')),
                  DropdownMenuItem(value: 'water', child: Text('Water')),
                  DropdownMenuItem(
                      value: 'fertilize', child: Text('Fertilize')),
                  DropdownMenuItem(value: 'pot_up', child: Text('Pot up')),
                  DropdownMenuItem(value: 'treat', child: Text('Treat')),
                  DropdownMenuItem(
                      value: 'mortality', child: Text('Mortality')),
                  DropdownMenuItem(
                      value: 'root_check', child: Text('Root check')),
                  DropdownMenuItem(value: 'move', child: Text('Move')),
                  DropdownMenuItem(
                      value: 'harden_off', child: Text('Harden off')),
                  DropdownMenuItem(value: 'note', child: Text('Note')),
                ],
                onChanged: (v) => setDialog(() => eventType = v ?? eventType),
              ),
              TextField(
                controller: deltaController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Count change (e.g. -3 for losses)',
                ),
              ),
              TextField(
                controller: notesController,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final now = nowUtcIso();
    final delta = int.tryParse(deltaController.text.trim());
    final newCount = delta != null
        ? ((batch.countCurrent ?? batch.countStarted ?? 0) + delta)
        : null;
    await widget.db.into(widget.db.batchEvents).insert(
          BatchEventsCompanion.insert(
            id: newId(),
            propertyId: batch.propertyId,
            batchId: batch.id,
            occurredAt: now,
            eventType: eventType,
            countDelta: Value(delta),
            countAfter: Value(newCount),
            notes: Value(notesController.text.trim().isEmpty
                ? null
                : notesController.text.trim()),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    if (newCount != null) {
      await (widget.db.update(widget.db.propagationBatches)
            ..where((b) => b.id.equals(batch.id)))
          .write(PropagationBatchesCompanion(
        countCurrent: Value(newCount),
        updatedAt: Value(now),
      ));
    }
    _load();
  }

  Future<void> _setStatus() async {
    final batch = _batch!;
    final status = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final s in [
              'active',
              'rooted',
              'hardening',
              'planted_out',
              'failed',
              'archived'
            ])
              ListTile(
                minTileHeight: 56,
                title: Text(s.replaceAll('_', ' ')),
                trailing: batch.status == s ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, s),
              ),
          ],
        ),
      ),
    );
    if (status == null) return;
    await (widget.db.update(widget.db.propagationBatches)
          ..where((b) => b.id.equals(batch.id)))
        .write(PropagationBatchesCompanion(
      status: Value(status),
      updatedAt: Value(nowUtcIso()),
    ));
    _load();
  }

  /// "Plant out": creates a planting event carrying the lineage link.
  Future<void> _plantOut() async {
    final batch = _batch!;
    final countController = TextEditingController(
        text: '${batch.countCurrent ?? batch.countStarted ?? ''}');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Plant out'),
        content: TextField(
          controller: countController,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Count planted'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create planting')),
        ],
      ),
    );
    if (saved != true) return;
    final count = int.tryParse(countController.text.trim());
    if (count == null || count <= 0) return;
    final now = nowUtcIso();
    await widget.db
        .into(widget.db.plantingEvents)
        .insert(PlantingEventsCompanion.insert(
          id: newId(),
          propertyId: batch.propertyId,
          taxonId: Value(batch.taxonId),
          plantedOn: now.substring(0, 10),
          stockSource: 'own_propagation',
          batchId: Value(batch.id),
          countPlanted: count,
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
    await (widget.db.update(widget.db.propagationBatches)
          ..where((b) => b.id.equals(batch.id)))
        .write(PropagationBatchesCompanion(
      status: const Value('planted_out'),
      updatedAt: Value(now),
    ));
    _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Planting created — find it under Plantings')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final batch = _batch;
    if (batch == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final species = _taxon?.commonName ?? _taxon?.scientificName ?? 'Unknown';
    return Scaffold(
      appBar: AppBar(
        title: Text(batch.batchCode ?? species),
        actions: [
          IconButton(
            icon: const Icon(Icons.flag_outlined),
            tooltip: 'Set status',
            onPressed: _setStatus,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Lineage view: the differentiator (spec §4.7).
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Lineage',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _lineageRow(
                      Icons.nature,
                      _sourcePlant?.label ?? 'No mother plant recorded',
                      _sourcePlant != null),
                  _lineageRow(
                      Icons.content_cut,
                      _collection != null
                          ? '${_collection!.materialType.replaceAll('_', ' ')} '
                              '× ${_collection!.quantity ?? '?'} on ${_collection!.collectedOn}'
                          : 'No collection event',
                      _collection != null),
                  _lineageRow(
                      Icons.science_outlined,
                      '$species — ${batch.method?.replaceAll('_', ' ') ?? 'unknown method'}, '
                      'started ${batch.startedOn}',
                      true),
                  for (final p in _plantings)
                    _lineageRow(Icons.park_outlined,
                        'Planted ${p.countPlanted} on ${p.plantedOn}', true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              title: Text(
                  '${batch.countCurrent ?? batch.countStarted ?? '?'} alive of '
                  '${batch.countStarted ?? '?'} started'),
              subtitle: Text('Status: ${batch.status ?? 'active'}'
                  '${batch.container != null ? ' · ${batch.container}' : ''}'),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add_task),
                    label: const Text('Log event'),
                    onPressed: _addEvent,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.park_outlined),
                    label: const Text('Plant out'),
                    onPressed: _plantOut,
                  ),
                ),
              ),
            ],
          ),
          if (_events.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Event log', style: Theme.of(context).textTheme.titleMedium),
            for (final e in _events)
              ListTile(
                minTileHeight: 48,
                dense: true,
                leading: const Icon(Icons.history),
                title: Text('${e.eventType.replaceAll('_', ' ')}'
                    '${e.countDelta != null ? ' (${e.countDelta! > 0 ? '+' : ''}${e.countDelta})' : ''}'),
                subtitle: Text([
                  e.occurredAt.substring(0, 10),
                  if (e.notes != null) e.notes!,
                ].join(' · ')),
              ),
          ],
        ],
      ),
    );
  }

  Widget _lineageRow(IconData icon, String text, bool present) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon,
              size: 20, color: present ? Colors.green.shade700 : Colors.grey),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style:
                    TextStyle(color: present ? null : Colors.grey.shade600)),
          ),
        ],
      ),
    );
  }
}
