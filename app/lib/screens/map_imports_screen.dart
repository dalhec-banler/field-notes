import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// The maps that have been imported into this place, and the way back out.
/// Removing an import removes the zones that arrived in it — nothing a person
/// drew by hand, which carries no import_id, is ever touched.
class MapImportsScreen extends StatefulWidget {
  const MapImportsScreen({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<MapImportsScreen> createState() => _MapImportsScreenState();
}

class _MapImportsScreenState extends State<MapImportsScreen> {
  late Future<List<MapImport>> _future = _load();

  final _open = <String>{};

  Future<List<Zone>> _zonesFromImport(String importId) =>
      (widget.db.select(widget.db.zones)
            ..where((z) => z.importId.equals(importId) & z.deletedAt.isNull())
            ..orderBy([(z) => OrderingTerm.asc(z.name)]))
          .get();

  Future<void> _setHidden(Zone z, bool hidden) async {
    await (widget.db.update(widget.db.zones)..where((t) => t.id.equals(z.id)))
        .write(ZonesCompanion(
            hidden: Value(hidden ? 1 : 0), updatedAt: Value(nowUtcIso())));
    if (mounted) setState(() {});
  }

  Future<void> _setAllHidden(String importId, bool hidden) async {
    await (widget.db.update(widget.db.zones)
          ..where((z) => z.importId.equals(importId) & z.deletedAt.isNull()))
        .write(ZonesCompanion(
            hidden: Value(hidden ? 1 : 0), updatedAt: Value(nowUtcIso())));
    if (mounted) setState(() {});
  }

  Future<List<MapImport>> _load() => (widget.db.select(widget.db.mapImports)
        ..where((t) =>
            t.propertyId.equals(widget.property.id) & t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
      .get();

  Future<void> _remove(MapImport imp) async {
    final db = widget.db;
    final live = await (db.select(db.zones)
          ..where((z) => z.importId.equals(imp.id) & z.deletedAt.isNull()))
        .get();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove this import?'),
        content: Text(live.length == 1
            ? 'One zone came in with "${imp.sourceName}". It goes too. '
              'Records stay where they are; they just stop naming a zone.'
            : '${live.length} zones came in with "${imp.sourceName}". They go too. '
              'Records stay where they are; they just stop naming a zone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: const Text('KEEP')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: const Text('REMOVE')),
        ],
      ),
    );
    if (ok != true) return;
    final now = nowUtcIso();
    final ids = live.map((z) => z.id).toList();
    await db.transaction(() async {
      if (ids.isNotEmpty) {
        await (db.update(db.observations)
              ..where((o) => o.zoneId.isIn(ids) & o.deletedAt.isNull()))
            .write(ObservationsCompanion(
                zoneId: const Value(null), updatedAt: Value(now)));
        await (db.update(db.zones)..where((z) => z.id.isIn(ids)))
            .write(ZonesCompanion(deletedAt: Value(now), updatedAt: Value(now)));
      }
      await (db.update(db.mapImports)..where((t) => t.id.equals(imp.id)))
          .write(MapImportsCompanion(
              deletedAt: Value(now), updatedAt: Value(now)));
    });
    if (!mounted) return;
    setState(() => _future = _load());
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ids.isEmpty
          ? 'Import removed. It had no zones left.'
          : 'Import removed, with ${ids.length} zone${ids.length == 1 ? '' : 's'}.'),
    ));
  }

  Color _swatch(String hex) {
    final v = hex.replaceFirst('#', '');
    final n = int.tryParse(v, radix: 16);
    return n == null ? Press.inkSoft : Color(0xFF000000 | n);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Imported maps')),
      body: FutureBuilder<List<MapImport>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return Center(child: MonoLabel('READING THE REGISTER'));
          }
          final rows = snap.data!;
          if (rows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'No maps have been imported into this place yet.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = rows[i];
              final counts = [
                if (r.zoneCount > 0) '${r.zoneCount} zone${r.zoneCount == 1 ? '' : 's'}',
                if (r.featureCount > 0)
                  '${r.featureCount} feature${r.featureCount == 1 ? '' : 's'}',
              ].join(' · ');
              final open = _open.contains(r.id);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Diamond(
                        size: 9,
                        color: r.sourceKind == 'link' ? Press.river : Press.sage),
                    title: Text(r.sourceName,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: MonoLabel(
                        '${r.sourceKind == 'link' ? 'LINK' : 'FILE'} · ${r.importedAt.substring(0, 10)}'
                        '${counts.isEmpty ? '' : ' · $counts'}'),
                    onTap: () => setState(
                        () => open ? _open.remove(r.id) : _open.add(r.id)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                            onPressed: () => _remove(r),
                            child: const Text('REMOVE')),
                        Icon(open ? Icons.expand_less : Icons.expand_more),
                      ],
                    ),
                  ),
                  if (open)
                    FutureBuilder<List<Zone>>(
                      future: _zonesFromImport(r.id),
                      builder: (context, zs) {
                        if (!zs.hasData) return const SizedBox(height: 8);
                        final zones = zs.data!;
                        if (zones.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.fromLTRB(56, 0, 16, 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text('No zones left from this import.'),
                            ),
                          );
                        }
                        final anyShown = zones.any((z) => z.hidden == 0);
                        return Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(56, 0, 12, 4),
                              child: Row(
                                children: [
                                  MonoLabel('ON THE MAP'),
                                  const Spacer(),
                                  TextButton(
                                    onPressed: () =>
                                        _setAllHidden(r.id, anyShown),
                                    child: Text(anyShown
                                        ? 'HIDE ALL'
                                        : 'SHOW ALL'),
                                  ),
                                ],
                              ),
                            ),
                            for (final z in zones)
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(56, 0, 12, 0),
                                child: Row(
                                  children: [
                                    if (z.colorHex != null)
                                      Container(
                                        width: 12,
                                        height: 12,
                                        margin: const EdgeInsets.only(right: 10),
                                        color: _swatch(z.colorHex!),
                                      ),
                                    Expanded(
                                      child: Text(
                                        z.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            color: z.hidden != 0
                                                ? Press.inkSoft
                                                    .withValues(alpha: 0.55)
                                                : null),
                                      ),
                                    ),
                                    if (z.areaAcres != null)
                                      MonoLabel(
                                          '${z.areaAcres!.toStringAsFixed(1)} AC'),
                                    Switch(
                                      value: z.hidden == 0,
                                      onChanged: (v) => _setHidden(z, !v),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 10),
                          ],
                        );
                      },
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
