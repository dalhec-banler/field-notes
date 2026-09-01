import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../theme/tokens.dart';
import 'press.dart';

/// "What's here": the records under one dot or cluster, grouped by species
/// (or record kind when unnamed), each group opening to its dated records.
/// Reached by tapping a cluster that can't split, or long-pressing any dot.
Future<void> showRecordsHereSheet(
  BuildContext context, {
  required FieldNotesDb db,
  required List<String> ids,
  ValueChanged<String>? onOpen,
}) async {
  if (ids.isEmpty) return;
  final rows = await db
      .customSelect(
        'SELECT o.id AS id, o.observed_at AS at, o.observation_type AS type, '
        'o.notes AS notes, COALESCE(t.common_name, t.scientific_name) AS species, '
        'z.name AS zone '
        'FROM observations o LEFT JOIN taxa t ON t.id = o.taxon_id '
        'LEFT JOIN zones z ON z.id = o.zone_id '
        'WHERE o.id IN (${List.filled(ids.length, '?').join(',')}) '
        'AND o.deleted_at IS NULL ORDER BY o.observed_at DESC',
        variables: [for (final id in ids) Variable.withString(id)],
      )
      .get();
  if (!context.mounted || rows.isEmpty) return;

  final groups = <String, List<QueryRow>>{};
  for (final r in rows) {
    final key =
        (r.data['species'] as String?) ??
        (r.data['type'] as String? ?? 'general').toUpperCase();
    (groups[key] ??= []).add(r);
  }
  final ordered = groups.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  final zone = rows.first.data['zone'] as String?;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Press.paper,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(Metrics.gutter, 14, Metrics.gutter, 24),
        children: [
          MonoLabel(
            '${rows.length} record${rows.length == 1 ? '' : 's'} here'
            '${zone != null ? ' · $zone' : ''}',
            size: 10,
            spacing: 2,
          ),
          SizedBox(height: 8),
          for (final g in ordered)
            _GroupTile(
              label: g.key,
              rows: g.value,
              onOpen: (id) {
                Navigator.of(ctx).pop();
                onOpen?.call(id);
              },
            ),
        ],
      ),
    ),
  );
}

class _GroupTile extends StatefulWidget {
  const _GroupTile({
    required this.label,
    required this.rows,
    required this.onOpen,
  });
  final String label;
  final List<QueryRow> rows;
  final ValueChanged<String> onOpen;

  @override
  State<_GroupTile> createState() => _GroupTileState();
}

class _GroupTileState extends State<_GroupTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Press.paperRaised,
        border: Border.all(color: Press.borderInk, width: 1.5),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Container(
              constraints: BoxConstraints(minHeight: Metrics.touchMin),
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 17,
                        color: Press.ink,
                      ),
                    ),
                  ),
                  MonoLabel('×${widget.rows.length}', size: 11, spacing: 1),
                  SizedBox(width: 8),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: Press.inkSoft,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            for (final r in widget.rows)
              InkWell(
                onTap: () => widget.onOpen(r.data['id'] as String),
                child: Container(
                  constraints: BoxConstraints(minHeight: Metrics.touchMin),
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Press.divider, width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            MonoLabel(
                              (r.data['at'] as String)
                                  .replaceFirst('T', ' ')
                                  .substring(0, 16),
                              size: 9,
                              opacity: 0.7,
                            ),
                            if ((r.data['notes'] as String?)?.isNotEmpty ??
                                false)
                              Text(
                                r.data['notes'] as String,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: Type.serif,
                                  fontSize: 14.5,
                                  color: Press.ink,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 20, color: Press.inkSoft),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
