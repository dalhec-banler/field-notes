import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/survival.dart';
import '../../services/tag_codes.dart';
import '../../widgets/plant_checkin_dialog.dart';
import 'plant_dossier_screen.dart';
import '../../theme/tokens.dart';
import '../../widgets/press.dart';

/// Cohort detail (spec §7.5): survival, tagged individuals, check-ins.
class PlantingDetailScreen extends StatefulWidget {
  const PlantingDetailScreen({
    super.key,
    required this.db,
    required this.eventId,
  });

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
    final event = await (db.select(
      db.plantingEvents,
    )..where((e) => e.id.equals(widget.eventId))).getSingleOrNull();
    if (event == null) return;
    TaxaData? taxon;
    if (event.taxonId != null) {
      taxon = await (db.select(
        db.taxa,
      )..where((t) => t.id.equals(event.taxonId!))).getSingleOrNull();
    }
    final individuals =
        await (db.select(db.plants)
              ..where((p) => p.plantingEventId.equals(event.id))
              ..where((p) => p.deletedAt.isNull())
              ..orderBy([(p) => OrderingTerm.asc(p.tagCode)]))
            .get();
    final checkins =
        await (db.select(db.plantCheckins)
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
    final planted = event.countPlanted;

    // Validated inside the dialog (audit M12/M13): 0 ≤ alive ≤ planted,
    // dead ≥ 0 when given, and alive + dead can't exceed the cohort.
    String? aliveError() {
      final t = aliveController.text.trim();
      if (t.isEmpty) return null;
      final n = int.tryParse(t);
      if (n == null || n < 0) return 'Whole number, 0 or more';
      if (n > planted) return 'Only $planted were planted';
      return null;
    }

    String? deadError() {
      final t = deadController.text.trim();
      if (t.isEmpty) return null;
      final n = int.tryParse(t);
      if (n == null || n < 0) return 'Whole number, 0 or more';
      final alive = int.tryParse(aliveController.text.trim());
      if (alive != null && alive + n > planted) {
        return 'Alive + dead can\'t exceed $planted';
      }
      return null;
    }

    bool valid() =>
        aliveController.text.trim().isNotEmpty &&
        aliveError() == null &&
        deadError() == null;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Cohort check-in'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: aliveController,
                keyboardType: TextInputType.number,
                autofocus: true,
                onChanged: (_) => setDialog(() {}),
                decoration: InputDecoration(
                  labelText: 'Alive (of $planted)',
                  errorText: aliveError(),
                ),
              ),
              TextField(
                controller: deadController,
                keyboardType: TextInputType.number,
                onChanged: (_) => setDialog(() {}),
                decoration: InputDecoration(
                  labelText: 'Dead (optional)',
                  errorText: deadError(),
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
              onPressed: valid() ? () => Navigator.pop(context, true) : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !valid()) return;
    final alive = int.parse(aliveController.text.trim());
    final now = nowUtcIso();
    await widget.db
        .into(widget.db.plantCheckins)
        .insert(
          PlantCheckinsCompanion.insert(
            id: newId(),
            propertyId: event.propertyId,
            plantingEventId: Value(event.id),
            checkedAt: now,
            status: 'alive',
            countAlive: Value(alive),
            countDead: Value(int.tryParse(deadController.text.trim())),
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
    _load();
  }

  Future<void> _addIndividual() async {
    final event = _event!;
    final last = await lastTagCode(widget.db, event.propertyId);
    final controller = TextEditingController(text: nextTagCode(last) ?? '');
    if (!mounted) return;

    // A tag code identifies one plant on a place (spec §4.8 UNIQUE
    // (property_id, tag_code)); check for a live duplicate before accepting.
    Future<bool> tagInUse(String code) async {
      final hit =
          await (widget.db.select(widget.db.plants)
                ..where((p) => p.propertyId.equals(event.propertyId))
                ..where((p) => p.tagCode.equals(code))
                ..where((p) => p.deletedAt.isNull())
                ..limit(1))
              .getSingleOrNull();
      return hit != null;
    }

    String? error;
    var checking = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          final code = controller.text.trim();
          Future<void> submit() async {
            if (code.isEmpty || checking) return;
            setDialog(() => checking = true);
            final dup = await tagInUse(code);
            if (!context.mounted) return;
            if (dup) {
              setDialog(() {
                checking = false;
                error = 'Tag "$code" is already on another plant here';
              });
              return;
            }
            Navigator.pop(context, true);
          }

          return AlertDialog(
            title: const Text('Tag an individual'),
            content: TextField(
              controller: controller,
              autofocus: true,
              onChanged: (_) => setDialog(() => error = null),
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                labelText: 'Tag code',
                helperText: 'Physical tag on the plant or cage',
                errorText: error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: code.isEmpty || checking ? null : submit,
                child: Text(checking ? 'Checking…' : 'Add'),
              ),
            ],
          );
        },
      ),
    );
    final code = controller.text.trim();
    if (saved != true || code.isEmpty) return;
    final now = nowUtcIso();
    await widget.db
        .into(widget.db.plants)
        .insert(
          PlantsCompanion.insert(
            id: newId(),
            propertyId: event.propertyId,
            plantingEventId: event.id,
            tagCode: Value(code),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    _load();
  }

  Future<void> _checkinIndividual(Plant plant) async {
    final wrote = await showPlantCheckinDialog(
      context,
      db: widget.db,
      plant: plant,
    );
    if (wrote) _load();
  }

  @override
  Widget build(BuildContext context) {
    final event = _event;
    if (event == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final species = _taxon?.scientificName ?? 'Unknown';
    final survival = _survival;
    final band = survival == null
        ? Press.inkSoft
        : survivalBandColor(survival.rate);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          (_taxon?.commonName ?? species).toUpperCase(),
          style: TextStyle(
            fontFamily: Type.slab,
            fontWeight: FontWeight.w900,
            fontSize: 20,
          ),
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
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: TaxonName(species, size: 24)),
                    // Only the cohort figure is a survival percent; the
                    // tag-derived one is over tagged plants (audit M13).
                    if (survival != null && !survival.fromTags)
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
                  opacity: 0.8,
                ),
                if (event.protection != null)
                  MonoLabel(
                    event.protection!.replaceAll('_', ' '),
                    size: 9.5,
                    opacity: 0.8,
                  ),
                if (survival != null) ...[
                  const SizedBox(height: 6),
                  MonoLabel(
                    survival.fromTags
                        ? '${survival.summary} · of ${survival.countPlanted} planted'
                        : '${survival.summary} · latest cohort check-in',
                    size: 9.5,
                    color: band,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          RailNote(
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
              spacing: 1.6,
            ),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Press.borderInk, width: 1.5),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < _individuals.length; i++)
                    InkWell(
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlantDossierScreen(
                              db: widget.db,
                              plantId: _individuals[i].id,
                            ),
                          ),
                        );
                        _load();
                      },
                      onLongPress: () => _checkinIndividual(_individuals[i]),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Press.paperRaised,
                          border: i < _individuals.length - 1
                              ? Border(
                                  bottom: BorderSide(
                                    color: Press.divider,
                                    width: 1,
                                  ),
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            Diamond(
                              size: 15,
                              color: plantStatusColor(
                                _individuals[i].currentStatus,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  MonoLabel(
                                    _individuals[i].tagCode ?? 'untagged',
                                    size: 11.5,
                                    spacing: 1.2,
                                    color: Press.ink,
                                    weight: FontWeight.w500,
                                  ),
                                  if (_individuals[i].lastCheckedAt != null)
                                    MonoLabel(
                                      'checked ${_individuals[i].lastCheckedAt!.substring(0, 10)}',
                                      size: 8.5,
                                      opacity: 0.65,
                                    ),
                                ],
                              ),
                            ),
                            StatusPill(
                              _individuals[i].currentStatus,
                              color: plantStatusColor(
                                _individuals[i].currentStatus,
                              ),
                              filled: _individuals[i].currentStatus == 'dead',
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
                    MonoLabel(
                      c.checkedAt.substring(0, 10),
                      size: 9.5,
                      color: Press.oxblood,
                    ),
                    const SizedBox(width: 10),
                    MonoLabel(
                      '${c.countAlive} alive'
                      '${c.countDead != null ? ' · ${c.countDead} dead' : ''}',
                      size: 9.5,
                      opacity: 0.85,
                    ),
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
