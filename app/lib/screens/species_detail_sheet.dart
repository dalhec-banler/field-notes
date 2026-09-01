import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';
import 'record_detail_screen.dart';

/// Species detail (spec §7.7: occurrence counts, first/last observed,
/// gallery). A sheet over the library: what this plant is, where and when
/// you've seen it here, every photo of it, and the star.
Future<void> showSpeciesDetailSheet(
  BuildContext context, {
  required FieldNotesDb db,
  required Property property,
  required TaxaData taxon,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Press.paper,
    builder: (ctx) => _SpeciesDetail(db: db, property: property, taxon: taxon),
  );
}

class _SpeciesDetail extends StatefulWidget {
  _SpeciesDetail({
    required this.db,
    required this.property,
    required this.taxon,
  });

  final FieldNotesDb db;
  final Property property;
  final TaxaData taxon;

  @override
  State<_SpeciesDetail> createState() => _SpeciesDetailState();
}

class _Sighting {
  _Sighting(this.obs, this.thumb, this.zoneName);
  final Observation obs;
  final String? thumb;
  final String? zoneName;
}

class _SpeciesDetailState extends State<_SpeciesDetail> {
  late TaxaData _taxon = widget.taxon;
  List<_Sighting> _sightings = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.db;
    final obs =
        await (db.select(db.observations)
              ..where((o) => o.propertyId.equals(widget.property.id))
              ..where((o) => o.taxonId.equals(widget.taxon.id))
              ..where((o) => o.deletedAt.isNull())
              ..orderBy([(o) => OrderingTerm.desc(o.observedAt)]))
            .get();
    final zones = {
      for (final z in await (db.select(
        db.zones,
      )..where((z) => z.propertyId.equals(widget.property.id))).get())
        z.id: z.name,
    };
    final out = <_Sighting>[];
    for (final o in obs) {
      String? thumb;
      final link =
          await (db.select(db.mediaLinks)
                ..where(
                  (l) =>
                      l.entityType.equals('observation') &
                      l.entityId.equals(o.id) &
                      l.deletedAt.isNull(),
                )
                ..limit(1))
              .getSingleOrNull();
      if (link != null) {
        final m = await (db.select(
          db.media,
        )..where((x) => x.id.equals(link.mediaId))).getSingleOrNull();
        if (m?.mediaType == 'photo') thumb = m!.thumbPath ?? m.localPath;
      }
      out.add(_Sighting(o, thumb, o.zoneId == null ? null : zones[o.zoneId]));
    }
    if (mounted) {
      setState(() {
        _sightings = out;
        _loaded = true;
      });
    }
  }

  Future<void> _toggleStar() async {
    final next = _taxon.isFavorite == 1 ? 0 : 1;
    await (widget.db.update(
      widget.db.taxa,
    )..where((t) => t.id.equals(_taxon.id))).write(
      TaxaCompanion(isFavorite: Value(next), updatedAt: Value(nowUtcIso())),
    );
    if (mounted) setState(() => _taxon = _taxon.copyWith(isFavorite: next));
  }

  String _date(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = _taxon;
    final starred = t.isFavorite == 1;
    final photos = _sightings.where((s) => s.thumb != null).toList();
    final first = _sightings.isEmpty ? null : _sightings.last.obs.observedAt;
    final last = _sightings.isEmpty ? null : _sightings.first.obs.observedAt;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(Metrics.gutter, 14, Metrics.gutter, 32),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (t.commonName != null)
                      Text(
                        t.commonName!,
                        style: TextStyle(
                          fontFamily: Type.slab,
                          fontWeight: FontWeight.w900,
                          fontSize: 26,
                          height: 1.0,
                          color: Press.ink,
                        ),
                      ),
                    SizedBox(height: 4),
                    TaxonName(t.scientificName, size: 17),
                    SizedBox(height: 6),
                    MonoLabel(
                      [
                        if (t.family != null) t.family!,
                        if (t.growthForm != null) t.growthForm!,
                        if (t.nativity != null) t.nativity!,
                      ].join(' · '),
                      size: 9,
                      spacing: 1.4,
                      opacity: 0.75,
                    ),
                  ],
                ),
              ),
              IconButton(
                iconSize: 30,
                icon: Icon(
                  starred ? Icons.star : Icons.star_border,
                  color: starred ? Press.gold : Press.inkSoft,
                ),
                tooltip: starred ? 'Un-star' : 'Star for quick pick',
                onPressed: _toggleStar,
              ),
            ],
          ),
          SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: Press.paperRaised,
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: Column(
              children: [
                FactRow(
                  'seen here',
                  '${_sightings.length} time${_sightings.length == 1 ? '' : 's'}',
                ),
                FactRow('first', first == null ? '—' : _date(first)),
                FactRow('last', last == null ? '—' : _date(last), last: true),
              ],
            ),
          ),
          if (!_loaded)
            Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (photos.isNotEmpty) ...[
            SizedBox(height: 16),
            MonoLabel('Photos', size: 9, spacing: 1.8),
            SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              children: [
                for (final s in photos)
                  GestureDetector(
                    onTap: () => _open(s),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Press.borderInk, width: 1),
                        image: DecorationImage(
                          image: FileImage(File(s.thumb!)),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (_sightings.isNotEmpty) ...[
            SizedBox(height: 16),
            MonoLabel('Sightings', size: 9, spacing: 1.8),
            const SizedBox(height: 4),
            for (final s in _sightings)
              InkWell(
                onTap: () => _open(s),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Press.divider, width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          [
                            _date(s.obs.observedAt),
                            s.zoneName ?? 'outside any zone',
                            if (s.obs.notes != null) s.obs.notes!,
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: Type.serif,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: Press.inkSoft),
                    ],
                  ),
                ),
              ),
          ] else if (_loaded)
            Padding(
              padding: EdgeInsets.only(top: 18),
              child: Text(
                'Not recorded on this place yet. Star it and it leads the '
                'picker when you next capture.',
                style: TextStyle(fontFamily: Type.serif, fontSize: 15),
              ),
            ),
        ],
      ),
    );
  }

  void _open(_Sighting s) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordDetailScreen(db: widget.db, obsId: s.obs.id),
      ),
    );
  }
}
