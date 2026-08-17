import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Species library (design README §3.5): the property's taxa with search,
/// nativity diamonds, and occurrence counts.
class SpeciesTab extends StatefulWidget {
  const SpeciesTab({super.key, required this.db, required this.property});

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
  Map<String, int> _occurrences = const {};

  @override
  void initState() {
    super.initState();
    _loadMeta();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadMeta() async {
    final favorites = await (widget.db.selectOnly(widget.db.taxa)
          ..addColumns([widget.db.taxa.id.count()])
          ..where(widget.db.taxa.isFavorite.equals(1) &
              widget.db.taxa.deletedAt.isNull()))
        .getSingle();
    final total = await (widget.db.selectOnly(widget.db.taxa)
          ..addColumns([widget.db.taxa.id.count()])
          ..where(widget.db.taxa.deletedAt.isNull()))
        .getSingle();
    // Occurrence counts per taxon on this property.
    final rows = await widget.db.customSelect(
      'SELECT taxon_id, COUNT(*) AS n FROM observations '
      "WHERE property_id = '${widget.property.id}' AND taxon_id IS NOT NULL "
      'AND deleted_at IS NULL GROUP BY taxon_id',
    ).get();
    if (mounted) {
      setState(() {
        _favoriteCount = favorites.read(widget.db.taxa.id.count()) ?? 0;
        _totalCount = total.read(widget.db.taxa.id.count()) ?? 0;
        _occurrences = {
          for (final r in rows)
            r.data['taxon_id'] as String: r.data['n'] as int
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = (widget.db.select(widget.db.taxa)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.isFavorite),
        (t) => OrderingTerm.asc(t.scientificName),
      ]));
    if (_query.isNotEmpty) {
      final q = '%$_query%';
      query.where((t) =>
          t.scientificName.like(q) | t.commonName.like(q) | t.family.like(q));
    }

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ScreenHeader(
              kicker: 'Property library · taxa', title: 'Species'),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Metrics.gutter, 10, Metrics.gutter, 0),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: const InputDecoration(
                hintText: 'Search scientific, common, or family…',
                isDense: true,
              ),
              style: const TextStyle(
                  fontFamily: Type.mono, fontSize: 11, color: Press.ink),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Metrics.gutter, 8, Metrics.gutter, 8),
            child: MonoLabel(
              '$_favoriteCount favourited palette · '
              '${_totalCount - _favoriteCount} regional seed · typo-tolerant',
              size: 9,
              opacity: 0.7,
            ),
          ),
          Expanded(
            child: StreamBuilder<List<TaxaData>>(
              stream: query.watch(),
              builder: (context, snapshot) {
                final taxa = snapshot.data ?? const [];
                if (taxa.isEmpty) {
                  return const Center(
                      child: MonoLabel('— no matches —',
                          size: 9, spacing: 2, opacity: 0.5));
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 110),
                  itemCount: taxa.length,
                  itemBuilder: (context, i) {
                    final t = taxa[i];
                    final invasive = t.nativity == 'invasive';
                    final diamondColor =
                        invasive ? Press.oxblood : Press.sageLight;
                    final count = _occurrences[t.id] ?? 0;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Metrics.gutter, vertical: 11),
                      decoration: const BoxDecoration(
                        border: Border(
                            bottom:
                                BorderSide(color: Press.divider, width: 1)),
                      ),
                      child: Row(
                        children: [
                          Diamond(size: 15, color: diamondColor),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TaxonName(t.scientificName,
                                    size: 17, maxLines: 1),
                                const SizedBox(height: 3),
                                MonoLabel(
                                  [
                                    if (t.commonName != null) t.commonName!,
                                    if (t.growthForm != null) t.growthForm!,
                                  ].join(' · '),
                                  size: 9,
                                  opacity: 0.72,
                                ),
                              ],
                            ),
                          ),
                          if (count > 0) ...[
                            BigNumber('$count', size: 17),
                            const SizedBox(width: 10),
                          ],
                          if (t.nativity != null)
                            StatusPill(
                              t.nativity!,
                              color:
                                  invasive ? Press.oxblood : Press.sage,
                            ),
                        ],
                      ),
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
