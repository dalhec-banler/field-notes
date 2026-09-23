import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/lineage.dart';
import '../../services/map_jump.dart';
import '../../theme/tokens.dart';
import '../../widgets/edit_sheet.dart';
import '../../widgets/nativity_chip.dart';
import '../../widgets/press.dart';
import '../../widgets/record_picker.dart';

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
  BatchLineage? _lineage;
  List<BatchEvent> _events = const [];
  List<PlantingEvent> _plantings = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.db;
    final l = await lineageOf(db, widget.batchId);
    if (l == null) {
      if (mounted) setState(() => _gone = true);
      return;
    }
    final events =
        await (db.select(db.batchEvents)
              ..where((e) => e.batchId.equals(l.batch.id))
              ..where((e) => e.deletedAt.isNull())
              ..orderBy([(e) => OrderingTerm.desc(e.occurredAt)]))
            .get();
    if (mounted) {
      setState(() {
        _lineage = l;
        _batch = l.batch;
        _taxon = l.taxon;
        _collection = l.collection;
        _sourcePlant = l.source;
        _events = events;
        _plantings = l.plantings;
      });
    }
  }

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
        ChoiceEdit(
          'method',
          'Method',
          options: propagationMethods,
          initial: b.method,
        ),
        TextEdit(
          'method_other',
          'Which method, if other',
          initial: b.methodOther,
        ),
        TextEdit('container', 'Container', initial: b.container),
        TextEdit('medium', 'Soil mix', initial: b.medium),
        TextEdit('location', 'Location', initial: b.location),
        NumberEdit('started_n', 'Count started', initial: b.countStarted),
        NumberEdit('current_n', 'Count now', initial: b.countCurrent),
        TextEdit('notes', 'Notes', initial: b.notes, lines: 3),
      ],
      deleteTitle: 'DELETE THIS BATCH?',
      // A batch listed under the place it was collected from or planted
      // out to is the same batch: deleting it there empties the bench too
      // (Austin, 2026-09-08). Say where it lives.
      deleteBody:
          'This is the batch on the bench at ${_lineage?.benchName ?? 'its bench'} — '
          'it is the same batch wherever it is listed, and it leaves every '
          'list. Its event log goes with it. Nothing is erased from disk.',
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
        methodOther: Value(
          r.text('method') == 'other' ? r.text('method_other') : null,
        ),
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

  static const _ordered = '__ordered__';

  /// Where the mother plant grows (D-029): one of the places — which is
  /// where the map link goes — or ordered, with the vendor as its origin.
  Future<void> _editSourcePlant(SourcePlant s) async {
    final places = await allProperties(widget.db);
    if (!mounted) return;
    final r = await showEditSheet(
      context,
      title: 'Edit mother plant',
      fields: [
        TextEdit('label', 'Label', initial: s.label, required: true),
        ChoiceEdit(
          'place',
          'Grows at',
          options: [
            for (final p in places) (p.id, p.name),
            (_ordered, 'Ordered / nursery'),
          ],
          initial: s.isOnProperty == 1 ? s.propertyId : _ordered,
        ),
        TextEdit(
          'origin',
          'Vendor / origin notes',
          initial: s.originNotes,
          hint: 'Sheffield\'s Seed Co, or where offsite',
        ),
      ],
    );
    if (r == null || r.deleted) return;
    final place = r.text('place');
    final ordered = place == null || place == _ordered;
    await (widget.db.update(
      widget.db.sourcePlants,
    )..where((x) => x.id.equals(s.id))).write(
      SourcePlantsCompanion(
        label: Value(r.text('label') ?? s.label),
        propertyId: ordered ? const Value.absent() : Value(place),
        isOnProperty: Value(ordered ? 0 : 1),
        originNotes: Value(r.text('origin')),
        // A plant that moved places no longer points at the old record.
        observationId: !ordered && place != s.propertyId
            ? const Value(null)
            : const Value.absent(),
        lat: !ordered && place != s.propertyId
            ? const Value(null)
            : const Value.absent(),
        lng: !ordered && place != s.propertyId
            ? const Value(null)
            : const Value.absent(),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    _load();
  }

  /// Point the mother plant at the record it was found as; the map link
  /// and the plate take their spot from it.
  Future<void> _linkRecord(SourcePlant s) async {
    final picked = await showRecordPicker(
      context,
      db: widget.db,
      propertyId: s.propertyId,
      taxonId: s.taxonId ?? _batch?.taxonId,
    );
    if (picked == null) return;
    await (widget.db.update(
      widget.db.sourcePlants,
    )..where((x) => x.id.equals(s.id))).write(
      SourcePlantsCompanion(
        observationId: Value(picked.id),
        lat: Value(picked.lat),
        lng: Value(picked.lng),
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
          options: materialTypes,
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

  /// "Plant out": a planting somewhere carrying the lineage link. The
  /// bench is rarely where the trees end up (D-029), so the place is asked
  /// — the last place this batch went to, else the bench.
  Future<void> _plantOut() async {
    final batch = _batch!;
    final places = await allProperties(widget.db);
    if (!mounted) return;
    var placeId = _plantings.isNotEmpty
        ? _plantings.last.propertyId
        : batch.propertyId;
    var protection = 'welded_wire_cage';
    final countController = TextEditingController(
      text: '${batch.countCurrent ?? batch.countStarted ?? ''}',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Plant out'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: placeId,
                decoration: const InputDecoration(labelText: 'Where'),
                items: [
                  for (final p in places)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: (v) => setDialog(() => placeId = v ?? placeId),
              ),
              TextField(
                controller: countController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Count planted'),
              ),
              DropdownButtonFormField<String>(
                initialValue: protection,
                decoration: const InputDecoration(labelText: 'Protection'),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('None')),
                  DropdownMenuItem(
                    value: 'welded_wire_cage',
                    child: Text('Welded wire cage'),
                  ),
                  DropdownMenuItem(
                    value: 'tree_tube',
                    child: Text('Tree tube'),
                  ),
                  DropdownMenuItem(value: 'fencing', child: Text('Fencing')),
                  DropdownMenuItem(
                    value: 'mulch_only',
                    child: Text('Mulch only'),
                  ),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => protection = v ?? protection,
              ),
            ],
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
      ),
    );
    if (saved != true) return;
    final count = int.tryParse(countController.text.trim());
    if (count == null || count <= 0) return;
    await plantOutFromBatch(
      widget.db,
      batch,
      propertyId: placeId,
      count: count,
      plantedOn: nowUtcIso().substring(0, 10),
      protection: protection,
    );
    _load();
    if (mounted) {
      final place = places.firstWhere((p) => p.id == placeId);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Planting created — find it under Plantings at ${place.name}',
          ),
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
                  _lineage?.originLine ?? 'chain starts at collection',
                  _sourcePlant != null,
                  first: true,
                  trailing: _sourceActions(),
                ),
                _stageRow(
                  'collection_events',
                  onTap: _collection == null
                      ? null
                      : () => _editCollection(_collection!),
                  _collection != null
                      ? '${labelFor(materialTypes, _collection!.materialType)} × ${_collection!.quantity ?? '?'}'
                      : 'No collection event',
                  _collection?.collectedOn ?? 'purchased or unknown lot',
                  _collection != null,
                ),
                _stageRow(
                  'propagation_batches',
                  species,
                  '${methodLabel(batch)} · started ${batch.startedOn} · '
                      'bench ${_lineage?.benchName ?? ''}',
                  true,
                ),
                for (var i = 0; i < _plantings.length; i++)
                  _stageRow(
                    'planting_events',
                    'Planted ${_plantings[i].countPlanted} at '
                        '${_lineage?.plantingPropertyNames[_plantings[i].propertyId] ?? '?'}',
                    _plantings[i].plantedOn,
                    true,
                    last: i == _plantings.length - 1,
                    trailing:
                        _plantings[i].lat != null && _plantings[i].lng != null
                        ? _mapButton(
                            _plantings[i].propertyId,
                            _plantings[i].lat!,
                            _plantings[i].lng!,
                          )
                        : null,
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

  /// The way back to the ground (D-029): fly the map to this spot, on
  /// whichever place it belongs to.
  Widget _mapButton(String propertyId, double lat, double lng, {String? id}) {
    return IconButton(
      tooltip: 'Show on the map',
      icon: const Icon(Icons.map_outlined, size: 20),
      onPressed: () {
        mapJump.value = MapJump(
          propertyId: propertyId,
          lat: lat,
          lng: lng,
          recordId: id,
        );
        Navigator.of(context).popUntil((r) => r.isFirst);
      },
    );
  }

  Widget? _sourceActions() {
    final s = _sourcePlant;
    final l = _lineage;
    if (s == null || l == null || s.isOnProperty != 1) return null;
    final spot = l.sourceSpot;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spot != null)
          _mapButton(s.propertyId, spot.$1, spot.$2, id: s.observationId),
        IconButton(
          tooltip: spot == null ? 'Link the record' : 'Change the record',
          icon: Icon(
            spot == null
                ? Icons.add_location_alt_outlined
                : Icons.edit_location_alt_outlined,
            size: 20,
          ),
          onPressed: () => _linkRecord(s),
        ),
      ],
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
    Widget? trailing,
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
          ?trailing,
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}
