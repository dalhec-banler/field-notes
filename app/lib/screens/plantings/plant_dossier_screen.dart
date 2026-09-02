import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../theme/tokens.dart';
import '../../widgets/plant_checkin_dialog.dart';
import '../../widgets/press.dart';

/// One plant's whole story (Austin's dossier note, 2026-09-01): the tag is
/// the identity; under it, where it came from (source plant → collection →
/// batch → planted), where it stands, and every check-in in order. The
/// phone captures; this page is the return visit.
class PlantDossierScreen extends StatefulWidget {
  const PlantDossierScreen({
    super.key,
    required this.db,
    required this.plantId,
  });

  final FieldNotesDb db;
  final String plantId;

  @override
  State<PlantDossierScreen> createState() => _PlantDossierScreenState();
}

class _PlantDossierScreenState extends State<PlantDossierScreen> {
  Plant? _plant;
  PlantingEvent? _event;
  TaxaData? _taxon;
  Zone? _zone;
  PropagationBatche? _batch;
  CollectionEvent? _collection;
  SourcePlant? _source;
  List<PlantCheckin> _checkins = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.db;
    // Check-ins depend only on the plant id — start that query first and
    // collect it last.
    final checkinsF =
        (db.select(db.plantCheckins)
              ..where((c) => c.plantId.equals(widget.plantId))
              ..where((c) => c.deletedAt.isNull())
              ..orderBy([(c) => OrderingTerm.desc(c.checkedAt)]))
            .get();
    final plant = await (db.select(
      db.plants,
    )..where((p) => p.id.equals(widget.plantId))).getSingleOrNull();
    if (plant == null) return;
    final event = await (db.select(
      db.plantingEvents,
    )..where((e) => e.id.equals(plant.plantingEventId))).getSingleOrNull();
    TaxaData? taxon;
    Zone? zone;
    PropagationBatche? batch;
    CollectionEvent? collection;
    SourcePlant? source;
    if (event != null) {
      // Taxon, zone and batch are independent once the event is known: the
      // futures start together and the awaits collect them.
      final taxonF = event.taxonId == null
          ? Future<TaxaData?>.value()
          : (db.select(
              db.taxa,
            )..where((t) => t.id.equals(event.taxonId!))).getSingleOrNull();
      final zoneF = event.zoneId == null
          ? Future<Zone?>.value()
          : (db.select(
              db.zones,
            )..where((z) => z.id.equals(event.zoneId!))).getSingleOrNull();
      final batchF = event.batchId == null
          ? Future<PropagationBatche?>.value()
          : (db.select(
              db.propagationBatches,
            )..where((b) => b.id.equals(event.batchId!))).getSingleOrNull();
      taxon = await taxonF;
      zone = await zoneF;
      batch = await batchF;
      if (batch?.collectionEventId != null) {
        collection =
            await (db.select(db.collectionEvents)
                  ..where((c) => c.id.equals(batch!.collectionEventId!)))
                .getSingleOrNull();
        if (collection?.sourcePlantId != null) {
          source =
              await (db.select(db.sourcePlants)
                    ..where((s) => s.id.equals(collection!.sourcePlantId!)))
                  .getSingleOrNull();
        }
      }
    }
    final checkins = await checkinsF;
    if (!mounted) return;
    setState(() {
      _plant = plant;
      _event = event;
      _taxon = taxon;
      _zone = zone;
      _batch = batch;
      _collection = collection;
      _source = source;
      _checkins = checkins;
    });
  }

  @override
  Widget build(BuildContext context) {
    final plant = _plant;
    if (plant == null) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final statusColor = plantStatusColor(plant.currentStatus);
    return Scaffold(
      appBar: AppBar(
        title: Text(plant.tagCode ?? 'Untagged plant'),
        actions: [
          TextButton(
            onPressed: () async {
              final wrote = await showPlantCheckinDialog(
                context,
                db: widget.db,
                plant: plant,
              );
              if (wrote) _load();
            },
            child: const Text('CHECK IN'),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(Metrics.gutter, 14, Metrics.gutter, 24),
        children: [
          // Identity: the tag is the identity; the species hangs off it.
          Kicker('The identity is the tag'),
          SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _taxon != null
                    ? TaxonName(_taxon!.scientificName, size: 28)
                    : Text(
                        'Species unknown',
                        style: TextStyle(
                          fontFamily: Type.slab,
                          fontWeight: FontWeight.w900,
                          fontSize: 24,
                        ),
                      ),
              ),
              StatusPill(plant.currentStatus, color: statusColor, filled: true),
            ],
          ),
          if (_taxon?.commonName != null)
            Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                _taxon!.commonName!,
                style: TextStyle(
                  fontFamily: Type.serif,
                  fontSize: 16,
                  color: Press.inkSoft,
                ),
              ),
            ),
          SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: Press.paperRaised,
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: Column(
              children: [
                if (_event != null) FactRow('Planted', _event!.plantedOn),
                if (_event != null)
                  FactRow('Stock', _event!.stockSource.replaceAll('_', ' ')),
                FactRow('Zone', _zone?.name ?? '—'),
                FactRow(
                  'Location',
                  plant.lat == null
                      ? '—'
                      : '${plant.lat!.toStringAsFixed(5)}, ${plant.lng!.toStringAsFixed(5)}',
                ),
                FactRow(
                  'Last checked',
                  plant.lastCheckedAt == null
                      ? 'never'
                      : plant.lastCheckedAt!.substring(0, 10),
                  last: true,
                ),
              ],
            ),
          ),

          // Lineage: the chain, oldest first, breaks tolerated at either end.
          SizedBox(height: 18),
          Kicker('Lineage'),
          SizedBox(height: 8),
          _lineage(),

          // Timeline.
          SizedBox(height: 18),
          Kicker('Check-ins · ${_checkins.length}'),
          SizedBox(height: 8),
          if (_checkins.isEmpty)
            Text(
              'No check-ins yet. The first one starts this plant\'s record '
              'of holding on.',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 15,
                height: 1.45,
              ),
            )
          else
            for (final c in _checkins) _checkinTile(c),
        ],
      ),
    );
  }

  Widget _lineage() {
    final steps = <(String, String)>[
      if (_source != null)
        (
          'Source',
          '${_source!.label}${_source!.originNotes != null ? ' · ${_source!.originNotes}' : ''}',
        ),
      if (_collection != null)
        (
          'Collected',
          '${_collection!.materialType.replaceAll('_', ' ')} · ${_collection!.collectedOn}',
        ),
      if (_batch != null)
        (
          'Batch',
          '${_batch!.batchCode ?? 'unlabelled'} · ${_batch!.method ?? 'method unrecorded'} · started ${_batch!.startedOn}',
        ),
      if (_event != null)
        (
          'Planted out',
          '${_event!.plantedOn} · ${_event!.countPlanted} in the cohort',
        ),
    ];
    if (steps.isEmpty) {
      return Text(
        'No lineage recorded — bought in, volunteered, or noted before the '
        'chain existed. The chain tolerates a break at either end.',
        style: TextStyle(fontFamily: Type.serif, fontSize: 15, height: 1.45),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Diamond(
                      size: 11,
                      color: Press.sage,
                      filled: i == steps.length - 1,
                    ),
                    if (i < steps.length - 1)
                      Container(
                        width: 2,
                        height: 26,
                        color: Press.divider,
                        margin: EdgeInsets.only(top: 3),
                      ),
                  ],
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MonoLabel(steps[i].$1, size: 8.5, spacing: 1.6),
                      SizedBox(height: 2),
                      Text(
                        steps[i].$2,
                        style: TextStyle(
                          fontFamily: Type.serif,
                          fontSize: 15,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _checkinTile(PlantCheckin c) {
    final bits = [
      if (c.heightCm != null) '${c.heightCm!.toStringAsFixed(0)} cm',
      if (c.vigor != null) 'vigor ${c.vigor}',
      if (c.browsePressure != null && c.browsePressure != 'none')
        'browse ${c.browsePressure}',
    ].join(' · ');
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Press.paperRaised,
        border: Border.all(color: Press.borderInk, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Diamond(size: 13, color: plantStatusColor(c.status)),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    MonoLabel(
                      c.checkedAt.substring(0, 10),
                      size: 9.5,
                      spacing: 1.2,
                    ),
                    Spacer(),
                    MonoLabel(
                      c.status.toUpperCase(),
                      size: 9,
                      spacing: 1.4,
                      color: plantStatusColor(c.status),
                    ),
                  ],
                ),
                if (bits.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: MonoLabel(bits, size: 9, opacity: 0.7),
                  ),
                if (c.notes != null && c.notes!.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: 5),
                    child: Text(
                      c.notes!,
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 14.5,
                        height: 1.4,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
