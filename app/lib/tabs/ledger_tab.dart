import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../screens/record_detail_screen.dart';
import '../services/app_prefs.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Ledger (design README §3.2): the feed as a record of entries. Rows scale
/// off one density root — 16 px glove, 13.5 px dense.
class LedgerTab extends StatefulWidget {
  const LedgerTab(
      {super.key,
      required this.db,
      required this.property,
      required this.prefs});

  final FieldNotesDb db;
  final Property property;
  final AppPrefs prefs;

  @override
  State<LedgerTab> createState() => _LedgerTabState();
}

class _LedgerTabState extends State<LedgerTab> {
  String? _zoneFilter;
  String? _typeFilter;
  String? _speciesFilter; // taxon id
  String? _speciesLabel;
  DateTimeRange? _dateFilter;
  List<Zone> _zones = const [];

  bool get _anyFilter =>
      _zoneFilter != null ||
      _typeFilter != null ||
      _speciesFilter != null ||
      _dateFilter != null;

  double get _em => widget.prefs.density == 'dense' ? 13.5 : 16.0;

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  /// Switching place (D-003) swaps the widget's property in place — the tab
  /// lives in an IndexedStack and never re-inits. Zones and any zone/species
  /// filter belong to the old place, so drop them and reload (audit M11).
  @override
  void didUpdateWidget(covariant LedgerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.property.id != widget.property.id) {
      setState(() {
        _zones = const [];
        _zoneFilter = null;
        _speciesFilter = null;
        _speciesLabel = null;
      });
      _loadZones();
    }
  }

  Future<void> _loadZones() async {
    final propertyId = widget.property.id;
    final zones = await (widget.db.select(widget.db.zones)
          ..where((z) => z.propertyId.equals(propertyId))
          ..where((z) => z.deletedAt.isNull())
          ..orderBy([(z) => OrderingTerm.asc(z.name)]))
        .get();
    // A slower load for the previous place must not overwrite the new one.
    if (mounted && widget.property.id == propertyId) {
      setState(() => _zones = zones);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = (widget.db.select(widget.db.observations)
      ..where((o) => o.propertyId.equals(widget.property.id))
      ..where((o) => o.deletedAt.isNull())
      ..orderBy([(o) => OrderingTerm.desc(o.observedAt)]));
    if (_zoneFilter != null) query.where((o) => o.zoneId.equals(_zoneFilter!));
    if (_typeFilter != null) {
      query.where((o) => o.observationType.equals(_typeFilter!));
    }
    if (_speciesFilter != null) {
      query.where((o) => o.taxonId.equals(_speciesFilter!));
    }
    final range = _dateFilter;
    if (range != null) {
      // observed_at is ISO-8601 UTC; day bounds in local time → UTC.
      final from = DateTime(range.start.year, range.start.month,
              range.start.day)
          .toUtc()
          .toIso8601String();
      final to = DateTime(range.end.year, range.end.month, range.end.day)
          .add(const Duration(days: 1))
          .toUtc()
          .toIso8601String();
      query.where((o) =>
          o.observedAt.isBiggerOrEqual(Constant(from)) &
          o.observedAt.isSmallerThan(Constant(to)));
    }

    return SafeArea(
      bottom: false,
      child: StreamBuilder<List<Observation>>(
        stream: query.watch(),
        builder: (context, snapshot) {
          final obs = snapshot.data ?? const [];
          return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ScreenHeader(
                    kicker: 'Record of entries',
                    title: 'Ledger',
                    trailing: MonoLabel(
                        '${obs.length} ${obs.length == 1 ? 'entry' : 'entries'}',
                        size: 9.5,
                        opacity: 0.7),
                  ),
                  SizedBox(
                    height: 60, // 44 dp chips + padding (glove target)
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: Metrics.gutter, vertical: 8),
                      children: [
                        _chip(
                          _zoneFilter == null
                              ? 'All zones'
                              : _zones
                                  .firstWhere((z) => z.id == _zoneFilter)
                                  .name,
                          active: _zoneFilter != null,
                          onTap: _pickZone,
                        ),
                        const SizedBox(width: 7),
                        _chip(
                          _typeFilter ?? 'Type',
                          active: _typeFilter != null,
                          onTap: _pickType,
                        ),
                        const SizedBox(width: 7),
                        _chip(
                          _speciesLabel ?? 'Species',
                          active: _speciesFilter != null,
                          onTap: _pickSpecies,
                        ),
                        const SizedBox(width: 7),
                        _chip(
                          _dateFilter == null
                              ? 'Dates'
                              : _fmtRange(_dateFilter!),
                          active: _dateFilter != null,
                          onTap: _pickDates,
                        ),
                        if (_anyFilter) ...[
                          const SizedBox(width: 7),
                          _chip('× Clear',
                              active: false,
                              onTap: () => setState(() {
                                    _zoneFilter = null;
                                    _typeFilter = null;
                                    _speciesFilter = null;
                                    _speciesLabel = null;
                                    _dateFilter = null;
                                  })),
                        ],
                      ],
                    ),
                  ),
                  Expanded(
                    child: obs.isEmpty
                        ? Center(
                            child: MonoLabel(
                                _anyFilter
                                    ? '— nothing matches this filter —'
                                    : '— no entries yet · tap the camera —',
                                size: 9,
                                spacing: 2,
                                opacity: 0.5))
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 110),
                            itemCount: obs.length + 1,
                            itemBuilder: (context, i) {
                              if (i == obs.length) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 22),
                                  child: Center(
                                    child: MonoLabel('— that\'s everything —',
                                        size: 9, spacing: 2, opacity: 0.5),
                                  ),
                                );
                              }
                              return _LedgerRow(
                                  db: widget.db, obs: obs[i], em: _em);
                            },
                          ),
                  ),
            ],
          );
        },
      ),
    );
  }

  Widget _chip(String label, {required bool active, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: active ? Press.ink : null,
          border: Border.all(color: Press.ink, width: 1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: Type.mono,
            fontSize: 9.5,
            letterSpacing: 1.6,
            color: active ? Press.paper : Press.ink,
          ),
        ),
      ),
    );
  }

  Future<void> _pickZone() async {
    final picked = await _pickSheet<Zone?>(
      title: 'Zone',
      items: [(null, 'All zones'), for (final z in _zones) (z, z.name)],
    );
    if (picked == null) return;
    setState(() => _zoneFilter = picked.$1?.id);
  }

  Future<void> _pickType() async {
    const types = [
      'general', 'plant', 'wildlife', 'problem', 'water', 'soil',
      'phenology', 'sign', 'weather', 'maintenance'
    ];
    final picked = await _pickSheet<String?>(
      title: 'Type',
      items: [(null, 'All types'), for (final t in types) (t, t)],
    );
    if (picked == null) return;
    setState(() => _typeFilter = picked.$1);
  }

  /// Species that actually have records on this place — not the whole
  /// library.
  Future<void> _pickSpecies() async {
    final rows = await widget.db.customSelect(
      'SELECT t.id AS id, t.common_name AS common, t.scientific_name AS sci, '
      'COUNT(o.id) AS n FROM taxa t '
      'JOIN observations o ON o.taxon_id = t.id '
      'WHERE o.property_id = ? AND o.deleted_at IS NULL '
      'GROUP BY t.id ORDER BY n DESC, common',
      variables: [Variable.withString(widget.property.id)],
      readsFrom: {widget.db.taxa, widget.db.observations},
    ).get();
    if (!mounted) return;
    final picked = await _pickSheet<String?>(
      title: 'Species',
      items: [
        (null, 'All species'),
        for (final r in rows)
          (
            r.data['id'] as String,
            '${(r.data['common'] as String?) ?? (r.data['sci'] as String)} · ${r.data['n']}'
          ),
      ],
    );
    if (picked == null) return;
    setState(() {
      _speciesFilter = picked.$1;
      _speciesLabel = picked.$1 == null ? null : picked.$2.split(' · ').first;
    });
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _dateFilter,
      helpText: 'SHOW RECORDS BETWEEN',
    );
    if (picked == null) return;
    setState(() => _dateFilter = picked);
  }

  String _fmtRange(DateTimeRange r) {
    String d(DateTime t) => '${t.month}/${t.day}';
    return '${d(r.start)} – ${d(r.end)}';
  }

  Future<(T, String)?> _pickSheet<T>({
    required String title,
    required List<(T, String)> items,
  }) {
    return showModalBottomSheet<(T, String)>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 14, 13, 6),
              child: MonoLabel(title, size: 9, spacing: 2),
            ),
            for (final item in items)
              ListTile(
                minTileHeight: 56,
                title: Text(item.$2.toUpperCase(),
                    style: const TextStyle(
                        fontFamily: Type.mono,
                        fontSize: 11,
                        letterSpacing: 1.4)),
                onTap: () => Navigator.pop(context, item),
              ),
          ],
        ),
      ),
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.db, required this.obs, required this.em});

  final FieldNotesDb db;
  final Observation obs;
  final double em;

  Future<(TaxaData?, String?)> _details() async {
    TaxaData? species;
    if (obs.taxonId != null) {
      species = await (db.select(db.taxa)
            ..where((x) => x.id.equals(obs.taxonId!)))
          .getSingleOrNull();
    }
    String? thumb;
    final link = await (db.select(db.mediaLinks)
          ..where((l) =>
              l.entityType.equals('observation') & l.entityId.equals(obs.id))
          ..limit(1))
        .getSingleOrNull();
    if (link != null) {
      final m = await (db.select(db.media)
            ..where((x) => x.id.equals(link.mediaId)))
          .getSingleOrNull();
      thumb = m?.thumbPath;
    }
    return (species, thumb);
  }

  String _relativeTime() {
    final then = DateTime.tryParse(obs.observedAt);
    if (then == null) return '';
    final d = DateTime.now().toUtc().difference(then);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    if (d.inHours < 24) return '${d.inHours} h';
    return '${d.inDays} d';
  }

  @override
  Widget build(BuildContext context) {
    final typeColor = recordTypeColor(obs.observationType);
    return FutureBuilder<(TaxaData?, String?)>(
      future: _details(),
      builder: (context, snapshot) {
        final (species, thumb) = snapshot.data ?? (null, null);
        return InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RecordDetailScreen(db: db, obsId: obs.id),
            ),
          ),
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: Metrics.gutter, vertical: em * 0.75),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Press.divider, width: 1)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: em * 3.6,
                  height: em * 4.2,
                  decoration: BoxDecoration(
                    color: Press.photoPlaceholder,
                    border: Border.all(color: Press.ink, width: 1),
                    image: thumb != null && File(thumb).existsSync()
                        ? DecorationImage(
                            image: FileImage(File(thumb)), fit: BoxFit.cover)
                        : null,
                  ),
                ),
                SizedBox(width: em * 0.7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Diamond(size: 7, color: typeColor),
                        const SizedBox(width: 5),
                        MonoLabel(obs.observationType,
                            size: em * 0.66, spacing: 1.6, color: typeColor),
                      ]),
                      SizedBox(height: em * 0.25),
                      // Common name leads — it's what was typed and what
                      // gets said out loud; the Latin sits under it.
                      if (species != null && species.commonName != null) ...[
                        Text(
                          species.commonName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: Type.slab,
                            fontWeight: FontWeight.w700,
                            fontSize: em * 1.15,
                            color: Press.ink,
                          ),
                        ),
                        TaxonName(species.scientificName,
                            size: em * 0.85, maxLines: 1),
                      ] else if (species != null)
                        TaxonName(species.scientificName,
                            size: em * 1.28, maxLines: 1)
                      else
                        Text(
                          obs.notes != null
                              ? 'Note'
                              : '${obs.observationType} record',
                          style: TextStyle(
                            fontFamily: Type.slab,
                            fontWeight: FontWeight.w700,
                            fontSize: em * 1.1,
                            color: Press.ink,
                          ),
                        ),
                      SizedBox(height: em * 0.2),
                      MonoLabel(
                        obs.gpsAccuracyM == -1
                            ? 'no fix · saved anyway'
                            : '${obs.lat.toStringAsFixed(5)}, ${obs.lng.toStringAsFixed(5)}',
                        size: em * 0.62,
                        opacity: 0.72,
                      ),
                      if (obs.notes != null) ...[
                        SizedBox(height: em * 0.25),
                        Text(
                          obs.notes!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: Type.serif,
                            fontSize: em * 0.88,
                            height: 1.4,
                            color: Press.ink,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: em * 0.5),
                MonoLabel(_relativeTime(),
                    size: em * 0.64, opacity: 0.6),
              ],
            ),
          ),
        );
      },
    );
  }
}
