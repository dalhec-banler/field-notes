import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../theme/tokens.dart';
import '../../widgets/press.dart';

/// Batch detail (spec §7.6): event log, status, counts, and the lineage view
/// from mother plant → collection → batch → plantings.
class BatchDetailScreen extends StatefulWidget {
  const BatchDetailScreen({super.key, required this.db, required this.batchId});

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
    final batch = await (db.select(
      db.propagationBatches,
    )..where((b) => b.id.equals(widget.batchId))).getSingleOrNull();
    if (batch == null) return;
    TaxaData? taxon;
    if (batch.taxonId != null) {
      taxon = await (db.select(
        db.taxa,
      )..where((t) => t.id.equals(batch.taxonId!))).getSingleOrNull();
    }
    CollectionEvent? collection;
    SourcePlant? sourcePlant;
    if (batch.collectionEventId != null) {
      collection = await (db.select(
        db.collectionEvents,
      )..where((c) => c.id.equals(batch.collectionEventId!))).getSingleOrNull();
      if (collection?.sourcePlantId != null) {
        sourcePlant =
            await (db.select(db.sourcePlants)
                  ..where((s) => s.id.equals(collection!.sourcePlantId!)))
                .getSingleOrNull();
      }
    }
    final events =
        await (db.select(db.batchEvents)
              ..where((e) => e.batchId.equals(batch.id))
              ..where((e) => e.deletedAt.isNull())
              ..orderBy([(e) => OrderingTerm.desc(e.occurredAt)]))
            .get();
    final plantings =
        await (db.select(db.plantingEvents)
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
    final current = batch.countCurrent ?? batch.countStarted ?? 0;

    // A loss can't take the batch below zero; say so inside the dialog
    // rather than writing a negative count.
    String? deltaError() {
      final t = deltaController.text.trim();
      if (t.isEmpty) return null;
      final d = int.tryParse(t);
      if (d == null) return 'Whole number, e.g. -3';
      if (current + d < 0) return 'Only $current in this batch';
      return null;
    }

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
                    value: 'fertilize',
                    child: Text('Fertilize'),
                  ),
                  DropdownMenuItem(value: 'pot_up', child: Text('Pot up')),
                  DropdownMenuItem(value: 'treat', child: Text('Treat')),
                  DropdownMenuItem(
                    value: 'mortality',
                    child: Text('Mortality'),
                  ),
                  DropdownMenuItem(
                    value: 'root_check',
                    child: Text('Root check'),
                  ),
                  DropdownMenuItem(value: 'move', child: Text('Move')),
                  DropdownMenuItem(
                    value: 'harden_off',
                    child: Text('Harden off'),
                  ),
                  DropdownMenuItem(value: 'note', child: Text('Note')),
                ],
                onChanged: (v) => setDialog(() => eventType = v ?? eventType),
              ),
              TextField(
                controller: deltaController,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
                onChanged: (_) => setDialog(() {}),
                decoration: InputDecoration(
                  labelText: 'Count change (e.g. -3 for losses)',
                  errorText: deltaError(),
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: deltaError() == null
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || deltaError() != null) return;
    final now = nowUtcIso();
    final delta = int.tryParse(deltaController.text.trim());
    // Clamped at zero as a last line of defence; the dialog already refuses.
    final newCount = delta != null ? (current + delta).clamp(0, 1 << 31) : null;
    await widget.db
        .into(widget.db.batchEvents)
        .insert(
          BatchEventsCompanion.insert(
            id: newId(),
            propertyId: batch.propertyId,
            batchId: batch.id,
            occurredAt: now,
            eventType: eventType,
            countDelta: Value(delta),
            countAfter: Value(newCount),
            notes: Value(
              notesController.text.trim().isEmpty
                  ? null
                  : notesController.text.trim(),
            ),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    if (newCount != null) {
      await (widget.db.update(
        widget.db.propagationBatches,
      )..where((b) => b.id.equals(batch.id))).write(
        PropagationBatchesCompanion(
          countCurrent: Value(newCount),
          updatedAt: Value(now),
        ),
      );
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
              'archived',
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
    await (widget.db.update(
      widget.db.propagationBatches,
    )..where((b) => b.id.equals(batch.id))).write(
      PropagationBatchesCompanion(
        status: Value(status),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    _load();
  }

  /// "Plant out": creates a planting event carrying the lineage link.
  Future<void> _plantOut() async {
    final batch = _batch!;
    final countController = TextEditingController(
      text: '${batch.countCurrent ?? batch.countStarted ?? ''}',
    );
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create planting'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final count = int.tryParse(countController.text.trim());
    if (count == null || count <= 0) return;
    final now = nowUtcIso();
    await widget.db
        .into(widget.db.plantingEvents)
        .insert(
          PlantingEventsCompanion.insert(
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
          ),
        );
    await (widget.db.update(
      widget.db.propagationBatches,
    )..where((b) => b.id.equals(batch.id))).write(
      PropagationBatchesCompanion(
        status: const Value('planted_out'),
        updatedAt: Value(now),
      ),
    );
    _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Planting created — find it under Plantings'),
        ),
      );
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
          // Lineage rail (README §3.4): stage diamonds + connectors. The
          // chain must tolerate a break at either end.
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: Press.paperRaised,
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _stageRow(
                  'source_plants',
                  _sourcePlant?.label ?? 'No mother plant recorded',
                  _sourcePlant != null
                      ? (_sourcePlant!.isOnProperty == 1
                            ? 'on property'
                            : _sourcePlant!.originNotes ?? 'offsite')
                      : 'chain starts at collection',
                  _sourcePlant != null,
                  first: true,
                ),
                _stageRow(
                  'collection_events',
                  _collection != null
                      ? '${_collection!.materialType.replaceAll('_', ' ')} × ${_collection!.quantity ?? '?'}'
                      : 'No collection event',
                  _collection?.collectedOn ?? 'purchased or unknown lot',
                  _collection != null,
                ),
                _stageRow(
                  'propagation_batches',
                  species,
                  '${batch.method?.replaceAll('_', ' ') ?? 'method unknown'} · started ${batch.startedOn}',
                  true,
                ),
                for (var i = 0; i < _plantings.length; i++)
                  _stageRow(
                    'planting_events',
                    'Planted ${_plantings[i].countPlanted}',
                    _plantings[i].plantedOn,
                    true,
                    last: i == _plantings.length - 1,
                  ),
                if (_plantings.isEmpty)
                  _stageRow(
                    'planting_events',
                    'Not planted out yet',
                    '—',
                    false,
                    last: true,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              title: Text(
                '${batch.countCurrent ?? batch.countStarted ?? '?'} alive of '
                '${batch.countStarted ?? '?'} started',
              ),
              subtitle: Text(
                'Status: ${batch.status ?? 'active'}'
                '${batch.container != null ? ' · ${batch.container}' : ''}',
              ),
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
                title: Text(
                  '${e.eventType.replaceAll('_', ' ')}'
                  '${e.countDelta != null ? ' (${e.countDelta! > 0 ? '+' : ''}${e.countDelta})' : ''}',
                ),
                subtitle: Text(
                  [
                    e.occurredAt.substring(0, 10),
                    if (e.notes != null) e.notes!,
                  ].join(' · '),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _stageRow(
    String stage,
    String title,
    String detail,
    bool present, {
    bool first = false,
    bool last = false,
  }) {
    final color = present ? Press.sage : Press.inkSoft.withValues(alpha: 0.4);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 24,
            child: Column(
              children: [
                if (!first)
                  Container(width: 1, height: 6, color: Press.divider),
                Diamond(size: 13, color: color, filled: present),
                if (!last)
                  Expanded(child: Container(width: 1, color: Press.divider)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MonoLabel(stage, size: 8.5, spacing: 1.8, opacity: 0.6),
                  const SizedBox(height: 2),
                  Text(
                    title.toUpperCase(),
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w700,
                      fontSize: 15.5,
                      color: present
                          ? Press.ink
                          : Press.inkSoft.withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(height: 2),
                  MonoLabel(detail, size: 9.5, opacity: 0.72),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
