import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import 'record_detail_screen.dart';

/// Feed (spec §7.3): reverse-chronological records with zone and type filters.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  String? _zoneFilter; // zone id
  String? _typeFilter;
  List<Zone> _zones = const [];

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  Future<void> _loadZones() async {
    final zones = await (widget.db.select(widget.db.zones)
          ..where((z) => z.propertyId.equals(widget.property.id))
          ..where((z) => z.deletedAt.isNull())
          ..orderBy([(z) => OrderingTerm.asc(z.name)]))
        .get();
    if (mounted) setState(() => _zones = zones);
  }

  @override
  Widget build(BuildContext context) {
    final query = (widget.db.select(widget.db.observations)
      ..where((o) => o.propertyId.equals(widget.property.id))
      ..where((o) => o.deletedAt.isNull())
      ..orderBy([(o) => OrderingTerm.desc(o.observedAt)]));
    if (_zoneFilter != null) {
      query.where((o) => o.zoneId.equals(_zoneFilter!));
    }
    if (_typeFilter != null) {
      query.where((o) => o.observationType.equals(_typeFilter!));
    }

    return Scaffold(
      appBar: AppBar(title: Text('Feed — ${widget.property.name}')),
      body: Column(
        children: [
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                if (_zones.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, top: 8),
                    child: _dropdownChip<String>(
                      label: _zoneFilter == null
                          ? 'Zone'
                          : _zones
                              .firstWhere((z) => z.id == _zoneFilter)
                              .name,
                      selected: _zoneFilter != null,
                      items: [
                        for (final z in _zones)
                          DropdownMenuItem(value: z.id, child: Text(z.name)),
                      ],
                      onChanged: (v) => setState(() => _zoneFilter = v),
                      onCleared: () => setState(() => _zoneFilter = null),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 8),
                  child: _dropdownChip<String>(
                    label: _typeFilter ?? 'Type',
                    selected: _typeFilter != null,
                    items: const [
                      DropdownMenuItem(value: 'general', child: Text('general')),
                      DropdownMenuItem(value: 'plant', child: Text('plant')),
                      DropdownMenuItem(
                          value: 'wildlife', child: Text('wildlife')),
                      DropdownMenuItem(value: 'problem', child: Text('problem')),
                      DropdownMenuItem(value: 'water', child: Text('water')),
                      DropdownMenuItem(value: 'soil', child: Text('soil')),
                      DropdownMenuItem(
                          value: 'phenology', child: Text('phenology')),
                      DropdownMenuItem(value: 'sign', child: Text('sign')),
                      DropdownMenuItem(value: 'weather', child: Text('weather')),
                      DropdownMenuItem(
                          value: 'maintenance', child: Text('maintenance')),
                    ],
                    onChanged: (v) => setState(() => _typeFilter = v),
                    onCleared: () => setState(() => _typeFilter = null),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Observation>>(
              stream: query.watch(),
              builder: (context, snapshot) {
                final obs = snapshot.data ?? const [];
                if (obs.isEmpty) {
                  return const Center(child: Text('No records match.'));
                }
                return ListView.builder(
                  itemCount: obs.length,
                  itemBuilder: (context, i) => _ObservationTile(
                    db: widget.db,
                    obs: obs[i],
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RecordDetailScreen(
                            db: widget.db, obsId: obs[i].id),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _dropdownChip<T>({
    required String label,
    required bool selected,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    required VoidCallback onCleared,
  }) {
    return InputChip(
      label: Text(label),
      selected: selected,
      onDeleted: selected ? onCleared : null,
      onPressed: () async {
        final value = await showModalBottomSheet<T>(
          context: context,
          builder: (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final item in items)
                  ListTile(
                    minTileHeight: 56,
                    title: item.child,
                    onTap: () => Navigator.pop(context, item.value),
                  ),
              ],
            ),
          ),
        );
        if (value != null) onChanged(value);
      },
    );
  }
}

class _ObservationTile extends StatelessWidget {
  const _ObservationTile(
      {required this.db, required this.obs, required this.onTap});

  final FieldNotesDb db;
  final Observation obs;
  final VoidCallback onTap;

  Future<(String?, String?)> _details() async {
    String? species;
    if (obs.taxonId != null) {
      final t = await (db.select(db.taxa)
            ..where((x) => x.id.equals(obs.taxonId!)))
          .getSingleOrNull();
      species = t?.commonName ?? t?.scientificName;
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

  @override
  Widget build(BuildContext context) {
    final when = obs.observedAt.replaceFirst('T', ' ').substring(0, 16);
    return FutureBuilder<(String?, String?)>(
      future: _details(),
      builder: (context, snapshot) {
        final (species, thumb) = snapshot.data ?? (null, null);
        return ListTile(
          minTileHeight: 64,
          onTap: onTap,
          leading: thumb != null && File(thumb).existsSync()
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(thumb),
                      width: 48, height: 48, fit: BoxFit.cover),
                )
              : CircleAvatar(child: Icon(_iconFor(obs.observationType))),
          title: Text(species ?? obs.observationType),
          subtitle: Text(
            [when, if (obs.notes != null) obs.notes!].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  IconData _iconFor(String type) => switch (type) {
        'plant' => Icons.local_florist_outlined,
        'wildlife' => Icons.pets_outlined,
        'water' => Icons.water_drop_outlined,
        'problem' => Icons.report_problem_outlined,
        _ => Icons.note_outlined,
      };
}
