import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../theme/tokens.dart';
import '../../widgets/edit_sheet.dart';
import '../../widgets/nativity_chip.dart';
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
  bool _gone = false;
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
    if (batch == null) {
      if (mounted) setState(() => _gone = true);
      return;
    }
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

  static const _methods = [
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
  static const _eventTypes = [
    ('check', 'Check'),
    ('water', 'Water'),
    ('fertilize', 'Fertilize'),
    ('pot_up', 'Pot up'),
    ('treat', 'Treat'),
    ('mortality', 'Mortality'),
    ('root_check', 'Root check'),
    ('move', 'Move'),
    ('harden_off', 'Harden off'),
    ('note', 'Note'),
  ];
  static const _materials = [
    ('hardwood_cutting', 'Hardwood cutting'),
    ('softwood_cutting', 'Softwood cutting'),
    ('semi_hardwood_cutting', 'Semi-hardwood cutting'),
    ('seed', 'Seed'),
    ('sucker', 'Sucker'),
    ('division', 'Division'),
    ('layer', 'Layer'),
    ('transplant', 'Transplant'),
    ('scion', 'Scion'),
  ];

  /// Everything the batch was started with, including the day — a batch
  /// begun ten days ago and entered today must be able to say so
  /// (Austin, 2026-09-07).
  Future<void> _editBatch() async {
    final b = _batch!;
    final r = await showEditSheet(
      context,
      title: 'Edit batch',
      db: widget.db,
      fields: [
        SpeciesEdit('taxon', 'Species', initial: _taxon),
        TextEdit('code', 'Batch code', initial: b.batchCode),
        DateEdit('started', 'Started on', initial: b.startedOn),
        ChoiceEdit('method', 'Method', options: _methods, initial: b.method),
        TextEdit('container', 'Container', initial: b.container),
        TextEdit('medium', 'Medium', initial: b.medium),
        TextEdit('location', 'Location', initial: b.location),
        NumberEdit('started_n', 'Count started', initial: b.countStarted),
        NumberEdit('current_n', 'Count now', initial: b.countCurrent),
        TextEdit('notes', 'Notes', initial: b.notes, lines: 3),
      ],
      deleteTitle: 'DELETE THIS BATCH?',
      deleteBody: 'Its event log goes with it. Nothing is erased from disk.',
    );
    if (r == null) return;
    final now = nowUtcIso();
    final q = widget.db.update(widget.db.propagationBatches)
      ..where((x) => x.id.equals(b.id));
    if (r.deleted) {
      await q.write(
        PropagationBatchesCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
        ),
      );
      if (mounted) Navigator.pop(context);
      return;
    }
    await q.write(
      PropagationBatchesCompanion(
        taxonId: Value(r.taxon('taxon')?.id),
        batchCode: Value(r.text('code')),
        startedOn: Value(r.day('started') ?? b.startedOn),
        method: Value(r.text('method')),
        container: Value(r.text('container')),
        medium: Value(r.text('medium')),
        location: Value(r.text('location')),
        countStarted: Value(r.integer('started_n')),
        countCurrent: Value(r.integer('current_n')),
        notes: Value(r.text('notes')),
        updatedAt: Value(now),
      ),
    );
    _load();
  }

  Future<void> _editEvent(BatchEvent e) async {
    final batch = _batch!;
    final r = await showEditSheet(
      context,
      title: 'Edit event',
      fields: [
        DateEdit('on', 'Happened on', initial: e.occurredAt),
        ChoiceEdit('type', 'Event', options: _eventTypes, initial: e.eventType),
        NumberEdit(
          'delta',
          'Count change',
          initial: e.countDelta,
          signed: true,
          hint: 'e.g. -3 for losses',
        ),
        TextEdit('notes', 'Notes', initial: e.notes, lines: 2),
      ],
      deleteTitle: 'DELETE THIS EVENT?',
      deleteBody: 'The batch count is put back by what this event took.',
    );
    if (r == null) return;
    final now = nowUtcIso();
    final q = widget.db.update(widget.db.batchEvents)
      ..where((x) => x.id.equals(e.id));
    final newDelta = r.deleted ? 0 : r.integer('delta');
    // The batch's running count follows the event's count change.
    final shift = (newDelta ?? 0) - (e.countDelta ?? 0);
    if (r.deleted) {
      await q.write(
        BatchEventsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
    } else {
      await q.write(
        BatchEventsCompanion(
          occurredAt: Value(withDay(e.occurredAt, r.day('on') ?? e.occurredAt)),
          eventType: Value(r.text('type') ?? e.eventType),
          countDelta: Value(newDelta),
          notes: Value(r.text('notes')),
          updatedAt: Value(now),
        ),
      );
    }
    if (shift != 0) {
      final current = batch.countCurrent ?? batch.countStarted ?? 0;
      await (widget.db.update(
        widget.db.propagationBatches,
      )..where((x) => x.id.equals(batch.id))).write(
        PropagationBatchesCompanion(
          countCurrent: Value((current + shift).clamp(0, 1 << 31)),
          updatedAt: Value(now),
        ),
      );
    }
    _load();
  }

  Future<void> _editSourcePlant(SourcePlant s) async {
    final r = await showEditSheet(
      context,
      title: 'Edit mother plant',
      fields: [
        TextEdit('label', 'Label', initial: s.label, required: true),
        ToggleEdit('on', 'On this property', initial: s.isOnProperty == 1),
        TextEdit(
          'origin',
          'Origin notes',
          initial: s.originNotes,
          hint: 'Where it came from, if offsite',
        ),
      ],
    );
    if (r == null || r.deleted) return;
    await (widget.db.update(
      widget.db.sourcePlants,
    )..where((x) => x.id.equals(s.id))).write(
      SourcePlantsCompanion(
        label: Value(r.text('label') ?? s.label),
        isOnProperty: Value(r.flag('on') ? 1 : 0),
        originNotes: Value(r.text('origin')),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    _load();
  }

  Future<void> _editCollection(CollectionEvent c) async {
    final r = await showEditSheet(
      context,
      title: 'Edit collection',
      fields: [
        DateEdit('on', 'Collected on', initial: c.collectedOn),
        ChoiceEdit(
          'material',
          'Material',
          options: _materials,
          initial: c.materialType,
        ),
        NumberEdit('qty', 'Quantity', initial: c.quantity),
        TextEdit('collector', 'Collector', initial: c.collector),
        TextEdit('notes', 'Notes', initial: c.notes, lines: 2),
      ],
    );
    if (r == null || r.deleted) return;
    await (widget.db.update(
      widget.db.collectionEvents,
    )..where((x) => x.id.equals(c.id))).write(
      CollectionEventsCompanion(
        collectedOn: Value(r.day('on') ?? c.collectedOn),
        materialType: Value(r.text('material') ?? c.materialType),
        quantity: Value(r.integer('qty')),
        collector: Value(r.text('collector')),
        notes: Value(r.text('notes')),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    _load();
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
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: _gone
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'This batch is gone from the ledger — removed here or '
                    'on another device.',
                    textAlign: TextAlign.center,
                  ),
                )
              : const CircularProgressIndicator(),
        ),
      );
    }
    final species = _taxon?.commonName ?? _taxon?.scientificName ?? 'Unknown';
    return Scaffold(
      appBar: AppBar(
        title: Text(batch.batchCode ?? species),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit batch',
            onPressed: _editBatch,
          ),
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
                  onTap: _sourcePlant == null
                      ? null
                      : () => _editSourcePlant(_sourcePlant!),
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
                  onTap: _collection == null
                      ? null
                      : () => _editCollection(_collection!),
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
              trailing: NativityChip(_taxon?.nativity),
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
                onTap: () => _editEvent(e),
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
    VoidCallback? onTap,
  }) {
    final color = present ? Press.sage : Press.inkSoft.withValues(alpha: 0.4);
    final row = IntrinsicHeight(
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
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}
