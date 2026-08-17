import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';

/// Species quick-pick: search common/scientific/family, favorites first.
class SpeciesField extends StatefulWidget {
  const SpeciesField({
    super.key,
    required this.db,
    required this.onSelected,
    this.label = 'Species (optional)',
    this.initial,
  });

  final FieldNotesDb db;
  final ValueChanged<TaxaData?> onSelected;
  final String label;
  final TaxaData? initial;

  @override
  State<SpeciesField> createState() => _SpeciesFieldState();
}

class _SpeciesFieldState extends State<SpeciesField> {
  late final TextEditingController _controller = TextEditingController(
      text: widget.initial?.commonName ?? widget.initial?.scientificName ?? '');
  List<TaxaData> _suggestions = const [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _suggestions = const []);
      widget.onSelected(null);
      return;
    }
    final q = '%${query.trim()}%';
    final rows = await (widget.db.select(widget.db.taxa)
          ..where((t) =>
              t.deletedAt.isNull() &
              (t.commonName.like(q) |
                  t.scientificName.like(q) |
                  t.family.like(q)))
          ..orderBy([
            (t) => OrderingTerm.desc(t.isFavorite),
            (t) => OrderingTerm.asc(t.scientificName),
          ])
          ..limit(10))
        .get();
    if (mounted) setState(() => _suggestions = rows);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          onChanged: _search,
          decoration: InputDecoration(
            labelText: widget.label,
            prefixIcon: const Icon(Icons.local_florist_outlined),
            border: const OutlineInputBorder(),
          ),
        ),
        for (final t in _suggestions)
          ListTile(
            minTileHeight: 48,
            dense: true,
            leading: t.isFavorite == 1
                ? const Icon(Icons.star, size: 18)
                : const SizedBox(width: 18),
            title: Text(t.commonName ?? t.scientificName),
            subtitle: Text(t.scientificName),
            onTap: () {
              _controller.text = t.commonName ?? t.scientificName;
              widget.onSelected(t);
              setState(() => _suggestions = const []);
            },
          ),
      ],
    );
  }
}
