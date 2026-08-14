import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';

/// Feed (spec §7.3): reverse-chronological records. Filters by zone/type/
/// species/date/author arrive with the rest of Milestone 1.
class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  Widget build(BuildContext context) {
    final query = (db.select(db.observations)
      ..where((o) => o.propertyId.equals(property.id))
      ..where((o) => o.deletedAt.isNull())
      ..orderBy([(o) => OrderingTerm.desc(o.observedAt)]));

    return Scaffold(
      appBar: AppBar(title: Text('Feed — ${property.name}')),
      body: StreamBuilder<List<Observation>>(
        stream: query.watch(),
        builder: (context, snapshot) {
          final obs = snapshot.data ?? const [];
          if (obs.isEmpty) {
            return const Center(child: Text('No records yet.'));
          }
          return ListView.builder(
            itemCount: obs.length,
            itemBuilder: (context, i) => _ObservationTile(db: db, obs: obs[i]),
          );
        },
      ),
    );
  }
}

class _ObservationTile extends StatelessWidget {
  const _ObservationTile({required this.db, required this.obs});

  final FieldNotesDb db;
  final Observation obs;

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
