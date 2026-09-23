import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../screens/species_detail_sheet.dart';
import '../species/add_species_sheet.dart';
import '../species/state_list_card.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Per-taxon presence on this place: count, first and last observed.
class _Seen {
  _Seen(this.count, this.first, this.last);
  final int count;
  final String? first;
  final String? last;
}

/// Species library (design README §3.5): the property's taxa with search,
/// nativity diamonds, and occurrence counts.
class SpeciesTab extends StatefulWidget {
  SpeciesTab({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<SpeciesTab> createState() => _SpeciesTabState();
}

class _SpeciesTabState extends State<SpeciesTab> {
  final _searchController = TextEditingController();
  String _query = '';
  int _favoriteCount = 0;
  int _totalCount = 0;

  late Stream<Map<String, _Seen>> _occurrences = _occurrenceStream();

  @override
  void initState() {
    super.initState();
    _loadMeta();
  }

  @override
  void didUpdateWidget(SpeciesTab old) {
    super.didUpdateWidget(old);
    if (old.property.id != widget.property.id) {
      _occurrences = _occurrenceStream();
      _loadMeta();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadMeta() async {
    final favorites =
        await (widget.db.selectOnly(widget.db.taxa)
              ..addColumns([widget.db.taxa.id.count()])
              ..where(
                widget.db.taxa.isFavorite.equals(1) &
                    widget.db.taxa.deletedAt.isNull(),
              ))
            .getSingle();
    final total =
        await (widget.db.selectOnly(widget.db.taxa)
              ..addColumns([widget.db.taxa.id.count()])
              ..where(widget.db.taxa.deletedAt.isNull()))
            .getSingle();
    if (mounted) {
      setState(() {
        _favoriteCount = favorites.read(widget.db.taxa.id.count()) ?? 0;
        _totalCount = total.read(widget.db.taxa.id.count()) ?? 0;
      });
    }
  }

  /// Occurrence counts + first/last observed per taxon on this property,
  /// live — a species you just recorded shows up without a restart.
  Stream<Map<String, _Seen>> _occurrenceStream() {
    return widget.db
        .customSelect(
          'SELECT taxon_id, COUNT(*) AS n, MIN(observed_at) AS first_at, '
          'MAX(observed_at) AS last_at FROM observations '
          'WHERE property_id = ? AND taxon_id IS NOT NULL '
          'AND deleted_at IS NULL GROUP BY taxon_id',
          variables: [Variable.withString(widget.property.id)],
          readsFrom: {widget.db.observations},
        )
        .watch()
        .map(
          (rows) => {
            for (final r in rows)
              r.data['taxon_id'] as String: _Seen(
                r.data['n'] as int,
                r.data['first_at'] as String?,
                r.data['last_at'] as String?,
              ),
          },
        );
  }

  String _short(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${m[d.month - 1]} ${d.day}';
  }

  /// Tap a row to star it: favourites lead the capture picker.
  Future<void> _toggleFavorite(TaxaData t) async {
    await (widget.db.update(
      widget.db.taxa,
    )..where((x) => x.id.equals(t.id))).write(
      TaxaCompanion(
        isFavorite: Value(t.isFavorite == 1 ? 0 : 1),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    _loadMeta();
  }

  @override
  Widget build(BuildContext context) {
    final query = (widget.db.select(widget.db.taxa)
      ..where((t) => t.deletedAt.isNull())
      // Common name leads the row, so it leads the sort; Latin-only taxa
      // fall in by their scientific name.
      ..orderBy([
        (t) => OrderingTerm.desc(t.isFavorite),
        (t) => OrderingTerm.asc(t.commonName.lower()),
        (t) => OrderingTerm.asc(t.scientificName),
      ]));
    if (_query.isNotEmpty) {
      final q = '%$_query%';
      query.where(
        (t) =>
            t.scientificName.like(q) | t.commonName.like(q) | t.family.like(q),
      );
    }

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(kicker: 'Property library · taxa', title: 'Species'),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Metrics.gutter,
              10,
              Metrics.gutter,
              0,
            ),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: const InputDecoration(
                hintText: 'Search scientific, common, or family…',
                isDense: true,
              ),
              style: TextStyle(
                fontFamily: Type.mono,
                fontSize: 11,
                color: Press.ink,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Metrics.gutter,
              8,
              Metrics.gutter,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: MonoLabel(
                    '$_favoriteCount starred · '
                    '${_totalCount - _favoriteCount} more regional · '
                    'star = quick pick · tap a row for its history',
                    size: 9,
                    opacity: 0.7,
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('ADD'),
                  onPressed: () async {
                    final added = await showAddSpeciesSheet(
                      context,
                      db: widget.db,
                      property: widget.property,
                    );
                    if (added != null) _loadMeta();
                  },
                ),
              ],
            ),
          ),
          StateListCard(
            db: widget.db,
            property: widget.property,
            onChanged: _loadMeta,
          ),
          Expanded(
            child: StreamBuilder<Map<String, _Seen>>(
              stream: _occurrences,
              builder: (context, occSnap) {
                final occurrences = occSnap.data ?? const <String, _Seen>{};
                return StreamBuilder<List<TaxaData>>(
                  stream: query.watch(),
                  builder: (context, snapshot) {
                    final taxa = snapshot.data ?? const [];
                    if (taxa.isEmpty) {
                      return Center(
                        child: MonoLabel(
                          '— no matches —',
                          size: 9,
                          spacing: 2,
                          opacity: 0.5,
                        ),
                      );
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.only(bottom: 110),
                      itemCount: taxa.length,
                      itemBuilder: (context, i) {
                        final t = taxa[i];
                        final invasive = t.nativity == 'invasive';
                        final starred = t.isFavorite == 1;
                        final seen = occurrences[t.id];
                        final count = seen?.count ?? 0;
                        return InkWell(
                          // Row → the species itself (sightings, photos);
                          // the star is its own target.
                          onTap: () => showSpeciesDetailSheet(
                            context,
                            db: widget.db,
                            property: widget.property,
                            taxon: t,
                          ),
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(
                              4,
                              4,
                              Metrics.gutter,
                              4,
                            ),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: Press.divider,
                                  width: 1,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                IconButton(
                                  iconSize: 22,
                                  tooltip: starred ? 'Un-star' : 'Star',
                                  icon: Icon(
                                    starred ? Icons.star : Icons.star_border,
                                    color: starred
                                        ? Press.gold
                                        : Press.inkSoft.withValues(alpha: 0.35),
                                  ),
                                  onPressed: () => _toggleFavorite(t),
                                ),
                                const SizedBox(width: 2),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // Common name leads; the Latin name
                                      // is the second line, like the ledger.
                                      if (t.commonName != null) ...[
                                        Text(
                                          t.commonName!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: Type.slab,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15.5,
                                            color: Press.ink,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        TaxonName(
                                          t.scientificName,
                                          size: 13,
                                          maxLines: 1,
                                        ),
                                      ] else
                                        TaxonName(
                                          t.scientificName,
                                          size: 17,
                                          maxLines: 1,
                                        ),
                                      if (t.growthForm != null) ...[
                                        const SizedBox(height: 3),
                                        MonoLabel(
                                          t.growthForm!,
                                          size: 9,
                                          opacity: 0.72,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                if (count > 0) ...[
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      BigNumber('$count', size: 17),
                                      MonoLabel(
                                        seen!.first == seen.last
                                            ? _short(seen.last)
                                            : '${_short(seen.first)} – ${_short(seen.last)}',
                                        size: 8,
                                        opacity: 0.65,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 10),
                                ],
                                // Native is the default here; only the
                                // exceptions earn a pill.
                                if (t.nativity != null &&
                                    t.nativity != 'native')
                                  StatusPill(
                                    t.nativity!,
                                    color: invasive
                                        ? Press.oxblood
                                        : Press.ochre,
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
