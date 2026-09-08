import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import 'nativity_chip.dart';

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
    text: widget.initial?.commonName ?? widget.initial?.scientificName ?? '',
  );
  List<TaxaData> _suggestions = const [];

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Empty field + focus → show the favourites so a first-timer sees that
    // tapping is enough; typing narrows from there.
    _focus.addListener(() {
      if (_focus.hasFocus && _controller.text.trim().isEmpty) {
        _showFavourites();
      }
    });
  }

  /// Monotonic query id: a slow older lookup must not overwrite the list
  /// for what's typed now.
  int _seq = 0;

  Future<void> _showFavourites() async {
    final mine = ++_seq;
    final rows =
        await (widget.db.select(widget.db.taxa)
              ..where((t) => t.deletedAt.isNull() & t.isFavorite.equals(1))
              ..orderBy([(t) => OrderingTerm.asc(t.commonName)])
              ..limit(8))
            .get();
    if (mounted && mine == _seq && _controller.text.trim().isEmpty) {
      setState(() => _suggestions = rows);
    }
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      widget.onSelected(null);
      await _showFavourites();
      return;
    }
    final mine = ++_seq;
    final q = '%${query.trim()}%';
    final rows =
        await (widget.db.select(widget.db.taxa)
              ..where(
                (t) =>
                    t.deletedAt.isNull() &
                    (t.commonName.like(q) |
                        t.scientificName.like(q) |
                        t.family.like(q)),
              )
              ..orderBy([
                (t) => OrderingTerm.desc(t.isFavorite),
                (t) => OrderingTerm.asc(t.scientificName),
              ])
              ..limit(10))
            .get();
    if (mounted && mine == _seq) setState(() => _suggestions = rows);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focus,
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
            trailing: NativityChip(t.nativity),
            onTap: () {
              _controller.text = t.commonName ?? t.scientificName;
              widget.onSelected(t);
              setState(() => _suggestions = const []);
              // Picked: the keyboard has nothing more to offer, and it was
              // hiding the rest of the form.
              _focus.unfocus();
            },
          ),
      ],
    );
  }
}
