import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';

/// Record detail (spec §7.4): photos, location, metadata, notes, soft delete.
class RecordDetailScreen extends StatefulWidget {
  const RecordDetailScreen({super.key, required this.db, required this.obsId});

  final FieldNotesDb db;
  final String obsId;

  @override
  State<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

class _RecordDetailScreenState extends State<RecordDetailScreen> {
  Observation? _obs;
  TaxaData? _taxon;
  Zone? _zone;
  List<MediaData> _photos = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.db;
    final obs = await (db.select(db.observations)
          ..where((o) => o.id.equals(widget.obsId)))
        .getSingleOrNull();
    if (obs == null) return;
    TaxaData? taxon;
    if (obs.taxonId != null) {
      taxon = await (db.select(db.taxa)
            ..where((t) => t.id.equals(obs.taxonId!)))
          .getSingleOrNull();
    }
    Zone? zone;
    if (obs.zoneId != null) {
      zone = await (db.select(db.zones)..where((z) => z.id.equals(obs.zoneId!)))
          .getSingleOrNull();
    }
    final links = await (db.select(db.mediaLinks)
          ..where((l) =>
              l.entityType.equals('observation') &
              l.entityId.equals(obs.id) &
              l.deletedAt.isNull())
          ..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]))
        .get();
    final photos = <MediaData>[];
    for (final link in links) {
      final m = await (db.select(db.media)
            ..where((x) => x.id.equals(link.mediaId)))
          .getSingleOrNull();
      if (m != null) photos.add(m);
    }
    if (mounted) {
      setState(() {
        _obs = obs;
        _taxon = taxon;
        _zone = zone;
        _photos = photos;
      });
    }
  }

  Future<void> _editNotes() async {
    final obs = _obs;
    if (obs == null) return;
    final controller = TextEditingController(text: obs.notes ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Notes'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    await (widget.db.update(widget.db.observations)
          ..where((o) => o.id.equals(obs.id)))
        .write(ObservationsCompanion(
      notes: Value(
          controller.text.trim().isEmpty ? null : controller.text.trim()),
      updatedAt: Value(nowUtcIso()),
    ));
    _load();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete record?'),
        content: const Text(
            'The record is removed from your feed. Photos stay on disk.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    // Soft delete (spec §4.1) — sync engines need tombstones.
    await (widget.db.update(widget.db.observations)
          ..where((o) => o.id.equals(widget.obsId)))
        .write(ObservationsCompanion(
      deletedAt: Value(nowUtcIso()),
      updatedAt: Value(nowUtcIso()),
    ));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final obs = _obs;
    if (obs == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final title = _taxon?.commonName ?? _taxon?.scientificName ??
        obs.observationType;
    final when = obs.observedAt.replaceFirst('T', ' ').substring(0, 16);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
              icon: const Icon(Icons.edit_note), onPressed: _editNotes),
          IconButton(
              icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: ListView(
        children: [
          if (_photos.isNotEmpty)
            SizedBox(
              height: 280,
              child: PageView(
                children: [
                  for (final m in _photos)
                    if (m.localPath != null && File(m.localPath!).existsSync())
                      Image.file(File(m.localPath!), fit: BoxFit.cover),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_taxon != null) ...[
                  Text(_taxon!.scientificName,
                      style: const TextStyle(fontStyle: FontStyle.italic)),
                  const SizedBox(height: 8),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                        avatar: const Icon(Icons.schedule, size: 18),
                        label: Text('$when ${obs.localTz}')),
                    if (_zone != null)
                      Chip(
                          avatar: const Icon(Icons.crop_square, size: 18),
                          label: Text(_zone!.name)),
                    Chip(
                      avatar: const Icon(Icons.gps_fixed, size: 18),
                      label: Text(obs.gpsAccuracyM == -1
                          ? 'No location'
                          : '${obs.lat.toStringAsFixed(5)}, '
                              '${obs.lng.toStringAsFixed(5)}'
                              '${obs.gpsAccuracyM != null ? ' ±${obs.gpsAccuracyM!.toStringAsFixed(0)} m' : ''}'),
                    ),
                    Chip(label: Text(obs.observationType)),
                  ],
                ),
                const SizedBox(height: 16),
                Text(obs.notes ?? 'No notes.',
                    style: Theme.of(context).textTheme.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
