import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/survival.dart';
import '../../services/tag_codes.dart';
import '../../theme/tokens.dart';
import '../../widgets/press.dart';

/// Cohort detail (spec §7.5): survival, tagged individuals, check-ins.
class PlantingDetailScreen extends StatefulWidget {
  const PlantingDetailScreen(
      {super.key, required this.db, required this.eventId});

  final FieldNotesDb db;
  final String eventId;

  @override
  State<PlantingDetailScreen> createState() => _PlantingDetailScreenState();
}

class _PlantingDetailScreenState extends State<PlantingDetailScreen> {
  PlantingEvent? _event;
  TaxaData? _taxon;
  SurvivalResult? _survival;
  List<Plant> _individuals = const [];
  List<PlantCheckin> _cohortCheckins = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.db;
    final event = await (db.select(db.plantingEvents)
          ..where((e) => e.id.equals(widget.eventId)))
        .getSingleOrNull();
    if (event == null) return;
    TaxaData? taxon;
    if (event.taxonId != null) {
      taxon = await (db.select(db.taxa)
            ..where((t) => t.id.equals(event.taxonId!)))
          .getSingleOrNull();
    }
    final individuals = await (db.select(db.plants)
          ..where((p) => p.plantingEventId.equals(event.id))
          ..where((p) => p.deletedAt.isNull())
          ..orderBy([(p) => OrderingTerm.asc(p.tagCode)]))
        .get();
    final checkins = await (db.select(db.plantCheckins)
          ..where((c) => c.plantingEventId.equals(event.id))
          ..where((c) => c.deletedAt.isNull())
          ..orderBy([(c) => OrderingTerm.desc(c.checkedAt)]))
        .get();
    final survival = await survivalFor(db, event);
    if (mounted) {
      setState(() {
        _event = event;
        _taxon = taxon;
        _individuals = individuals;
        _cohortCheckins = checkins;
        _survival = survival;
      });
    }
  }

  Future<void> _cohortCheckin() async {
    final event = _event!;
    final aliveController = TextEditingController();
    final deadController = TextEditingController();
    final notesController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cohort check-in'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: aliveController,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: 'Alive (of ${event.countPlanted})'),
            ),
            TextField(
              controller: deadController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Dead (optional)'),
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
    );
    if (saved != true) return;
    final alive = int.tryParse(aliveController.text.trim());
    if (alive == null) return;
    final now = nowUtcIso();
    await widget.db
        .into(widget.db.plantCheckins)
        .insert(PlantCheckinsCompanion.insert(
          id: newId(),
          propertyId: event.propertyId,
          plantingEventId: Value(event.id),
          checkedAt: now,
          status: 'alive',
          countAlive: Value(alive),
          countDead: Value(int.tryParse(deadController.text.trim())),
          notes: Value(notesController.text.trim().isEmpty
              ? null
              : notesController.text.trim()),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
    _load();
  }

  Future<void> _addIndividual() async {
    final event = _event!;
    final last = await lastTagCode(widget.db, event.propertyId);
    final controller =
        TextEditingController(text: nextTagCode(last) ?? '');
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tag an individual'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Tag code',
            helperText: 'Physical tag on the plant or cage',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add')),
        ],
      ),
    );
    if (saved != true || controller.text.trim().isEmpty) return;
    final now = nowUtcIso();
    await widget.db.into(widget.db.plants).insert(PlantsCompanion.insert(
          id: newId(),
          propertyId: event.propertyId,
          plantingEventId: event.id,
          tagCode: Value(controller.text.trim()),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
    _load();
  }

  Future<void> _checkinIndividual(Plant plant) async {
    var status = plant.currentStatus;
    final heightController = TextEditingController();
    String? vigor;
    String? browse;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text('Check in ${plant.tagCode ?? 'plant'}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: const [
                    DropdownMenuItem(value: 'alive', child: Text('Alive')),
                    DropdownMenuItem(value: 'dead', child: Text('Dead')),
                    DropdownMenuItem(value: 'missing', child: Text('Missing')),
                    DropdownMenuItem(value: 'dormant', child: Text('Dormant')),
                    DropdownMenuItem(value: 'browsed', child: Text('Browsed')),
                    DropdownMenuItem(
                        value: 'declining', child: Text('Declining')),
                    DropdownMenuItem(value: 'removed', child: Text('Removed')),
                  ],
                  onChanged: (v) => setDialog(() => status = v ?? status),
                ),
                TextField(
                  controller: heightController,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Height (cm)'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: vigor,
                  decoration: const InputDecoration(labelText: 'Vigor'),
                  items: const [
                    DropdownMenuItem(
                        value: 'excellent', child: Text('Excellent')),
                    DropdownMenuItem(value: 'good', child: Text('Good')),
                    DropdownMenuItem(value: 'fair', child: Text('Fair')),
                    DropdownMenuItem(value: 'poor', child: Text('Poor')),
                    DropdownMenuItem(value: 'dead', child: Text('Dead')),
                  ],
                  onChanged: (v) => setDialog(() => vigor = v),
                ),
                DropdownButtonFormField<String>(
                  initialValue: browse,
                  decoration:
                      const InputDecoration(labelText: 'Browse pressure'),
                  items: const [
                    DropdownMenuItem(value: 'none', child: Text('None')),
                    DropdownMenuItem(value: 'light', child: Text('Light')),
                    DropdownMenuItem(
                        value: 'moderate', child: Text('Moderate')),
                    DropdownMenuItem(value: 'severe', child: Text('Severe')),
                  ],
                  onChanged: (v) => setDialog(() => browse = v),
                ),
              ],
            ),
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
    await widget.db
        .into(widget.db.plantCheckins)
        .insert(PlantCheckinsCompanion.insert(
          id: newId(),
          propertyId: plant.propertyId,
          plantId: Value(plant.id),
          checkedAt: now,
          status: status,
          heightCm: Value(double.tryParse(heightController.text.trim())),
          vigor: Value(vigor),
          browsePressure: Value(browse),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
    await (widget.db.update(widget.db.plants)
          ..where((p) => p.id.equals(plant.id)))
        .write(PlantsCompanion(
      currentStatus: Value(status),
      lastCheckedAt: Value(now),
      updatedAt: Value(now),
    ));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final event = _event;
    if (event == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final species = _taxon?.scientificName ?? 'Unknown';
    final survival = _survival;
    final band =
        survival == null ? Press.inkSoft : survivalBandColor(survival.rate);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          (_taxon?.commonName ?? species).toUpperCase(),
          style: const TextStyle(
              fontFamily: Type.slab,
              fontWeight: FontWeight.w900,
              fontSize: 20),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Metrics.gutter),
        children: [
          // Cohort header on paper-raised (README §3.4).
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Press.paperRaised,
              border: Border.all(color: Press.ink, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: TaxonName(species, size: 24)),
                    if (survival != null)
                      Text(
                        '${(survival.rate * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontFamily: Type.slab,
                          fontWeight: FontWeight.w900,
                          fontSize: 26,
                          height: 1,
                          color: band,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                MonoLabel(
                    'planted ${event.plantedOn} · ${event.countPlanted} '
                    '${event.stockSource.replaceAll('_', ' ')}',
                    size: 9.5,
                    opacity: 0.8),
                if (event.protection != null)
                  MonoLabel(event.protection!.replaceAll('_', ' '),
                      size: 9.5, opacity: 0.8),
                if (survival != null) ...[
                  const SizedBox(height: 6),
                  MonoLabel(
                      '${survival.alive} / ${survival.total} · from '
                      '${survival.source == 'individuals' ? 'tagged individuals' : 'latest cohort check-in'}',
                      size: 9.5,
                      color: band),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          const RailNote(
            color: Press.sage,
            body:
                'Survival is derived on every read — latest status per tag, '
                'or the most recent cohort count. Never stored.',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: _cohortCheckin,
                    child: const Text('COHORT CHECK-IN'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _addIndividual,
                    child: const Text('TAG INDIVIDUAL'),
                  ),
                ),
              ),
            ],
          ),
          if (_individuals.isNotEmpty) ...[
            const SizedBox(height: 18),
            MonoLabel(
                'Tagged individuals · identity is the tag, not the pin',
                size: 9,
                spacing: 1.6),
            const SizedBox(height: 6),
            Container(
              decoration:
                  BoxDecoration(border: Border.all(color: Press.ink, width: 1.5)),
              child: Column(
                children: [
                  for (var i = 0; i < _individuals.length; i++)
                    InkWell(
                      onTap: () => _checkinIndividual(_individuals[i]),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 11, vertical: 10),
                        decoration: BoxDecoration(
                          color: Press.paperRaised,
                          border: i < _individuals.length - 1
                              ? const Border(
                                  bottom: BorderSide(
                                      color: Press.divider, width: 1))
                              : null,
                        ),
                        child: Row(
                          children: [
                            Diamond(
                                size: 15,
                                color: plantStatusColor(
                                    _individuals[i].currentStatus)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  MonoLabel(
                                      _individuals[i].tagCode ?? 'untagged',
                                      size: 11.5,
                                      spacing: 1.2,
                                      color: Press.ink,
                                      weight: FontWeight.w500),
                                  if (_individuals[i].lastCheckedAt != null)
                                    MonoLabel(
                                        'checked ${_individuals[i].lastCheckedAt!.substring(0, 10)}',
                                        size: 8.5,
                                        opacity: 0.65),
                                ],
                              ),
                            ),
                            StatusPill(
                              _individuals[i].currentStatus,
                              color: plantStatusColor(
                                  _individuals[i].currentStatus),
                              filled:
                                  _individuals[i].currentStatus == 'dead',
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (_cohortCheckins.isNotEmpty) ...[
            const SizedBox(height: 18),
            MonoLabel('Check-in history', size: 9, spacing: 1.6),
            const SizedBox(height: 6),
            for (final c in _cohortCheckins.where((c) => c.countAlive != null))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    MonoLabel(c.checkedAt.substring(0, 10),
                        size: 9.5, color: Press.oxblood),
                    const SizedBox(width: 10),
                    MonoLabel(
                        '${c.countAlive} alive'
                        '${c.countDead != null ? ' · ${c.countDead} dead' : ''}',
                        size: 9.5,
                        opacity: 0.85),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}
