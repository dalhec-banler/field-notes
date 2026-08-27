import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:native_exif/native_exif.dart';

import '../db/database.dart';
import '../geo/zone_assignment.dart';
import '../services/env_context.dart';
import '../services/media_store.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Geotagged photo import (spec §6): pick photos, read the GPS and time out
/// of their EXIF, review, and create one observation per photo at the
/// embedded coordinates. Photos without GPS still import — flagged as
/// unlocated (gps_accuracy_m = -1), never faked.
class PhotoImportScreen extends StatefulWidget {
  const PhotoImportScreen(
      {super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<PhotoImportScreen> createState() => _PhotoImportScreenState();
}

class _Candidate {
  _Candidate(this.file, {this.lat, this.lng, this.takenAt});
  final XFile file;
  final double? lat;
  final double? lng;
  final DateTime? takenAt; // UTC
  bool include = true;
  bool get located => lat != null && lng != null;
}

class _PhotoImportScreenState extends State<PhotoImportScreen> {
  List<_Candidate> _candidates = const [];
  bool _reading = false;
  bool _importing = false;
  String? _status;

  Future<void> _pick() async {
    setState(() {
      _status = null;
      _reading = true;
    });
    try {
      final files = await openFiles(acceptedTypeGroups: [
        const XTypeGroup(label: 'Photos', extensions: ['jpg', 'jpeg']),
      ]);
      final out = <_Candidate>[];
      for (final f in files) {
        double? lat;
        double? lng;
        DateTime? taken;
        try {
          final exif = await Exif.fromPath(f.path);
          try {
            final ll = await exif.getLatLong();
            if (ll != null) {
              lat = ll.latitude;
              lng = ll.longitude;
            }
            final dto = await exif.getAttribute<String>('DateTimeOriginal');
            taken = _parseExifDate(dto);
          } finally {
            await exif.close();
          }
        } catch (_) {
          // No EXIF on this platform/file: still importable, unlocated.
        }
        taken ??= (await f.lastModified()).toUtc();
        out.add(_Candidate(f, lat: lat, lng: lng, takenAt: taken));
      }
      if (!mounted) return;
      setState(() => _candidates = out);
    } catch (e) {
      if (mounted) setState(() => _status = 'Could not read photos: $e');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  /// EXIF "YYYY:MM:DD HH:MM:SS" is camera-local with no zone; treat it as
  /// the phone's local time.
  DateTime? _parseExifDate(String? s) {
    if (s == null || s.length < 19) return null;
    try {
      final d = DateTime(
        int.parse(s.substring(0, 4)),
        int.parse(s.substring(5, 7)),
        int.parse(s.substring(8, 10)),
        int.parse(s.substring(11, 13)),
        int.parse(s.substring(14, 16)),
        int.parse(s.substring(17, 19)),
      );
      return d.toUtc();
    } catch (_) {
      return null;
    }
  }

  Future<void> _import() async {
    if (_importing) return;
    final chosen = _candidates.where((c) => c.include).toList();
    if (chosen.isEmpty) return;
    setState(() {
      _importing = true;
      _status = 'Importing 0 of ${chosen.length}…';
    });
    final db = widget.db;
    var done = 0;
    var failed = 0;
    for (final c in chosen) {
      try {
        final bytes = await c.file.readAsBytes();
        final when = (c.takenAt ?? DateTime.now().toUtc()).toIso8601String();
        final media = await MediaStore(db).savePhoto(
          bytes,
          propertyId: widget.property.id,
          createdBy: 'local',
          lat: c.lat,
          lng: c.lng,
          capturedAt: when,
        );
        final obsId = newId();
        final now = nowUtcIso();
        final lat = c.lat ?? widget.property.centroidLat;
        final lng = c.lng ?? widget.property.centroidLng;
        final envService = EnvContextService(db);
        await db.transaction(() async {
          String? envId;
          if (lat != null && lng != null) {
            envId = await envService.createStale(
              propertyId: widget.property.id,
              lat: lat,
              lng: lng,
              resolvedFor: when.substring(0, 10),
            );
          }
          await db.into(db.observations).insert(ObservationsCompanion.insert(
                id: obsId,
                propertyId: widget.property.id,
                observedAt: when,
                localTz: localTzName(),
                lat: lat ?? 0,
                lng: lng ?? 0,
                // EXIF has no accuracy figure; null = located, unknown ±.
                gpsAccuracyM: Value(c.located ? null : -1),
                observationType: const Value('general'),
                notes: Value('Imported from ${c.file.name}'),
                envContextId: Value(envId),
                createdBy: 'local',
                createdAt: now,
                updatedAt: now,
              ));
          if (c.located) {
            await assignZone(db,
                observationId: obsId,
                propertyId: widget.property.id,
                lat: c.lat!,
                lng: c.lng!);
          }
          await MediaStore(db).linkTo(
            media.id,
            propertyId: widget.property.id,
            entityType: 'observation',
            entityId: obsId,
            role: 'primary',
          );
        });
        done++;
      } catch (_) {
        failed++;
      }
      if (mounted) {
        setState(() => _status = 'Importing $done of ${chosen.length}…');
      }
    }
    EnvContextService(db).backfillStale();
    if (!mounted) return;
    setState(() {
      _importing = false;
      _candidates = const [];
      _status =
          'Imported $done photo${done == 1 ? '' : 's'}${failed > 0 ? ' · $failed failed' : ''}. '
          'Find them in the Ledger.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final located = _candidates.where((c) => c.located).length;
    final chosen = _candidates.where((c) => c.include).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Import photos')),
      body: ListView(
        padding: const EdgeInsets.all(Metrics.gutter),
        children: [
          const Text(
            'Pick photos from your phone. Ones with GPS in them land on the '
            'map where they were taken; the rest still import, marked as '
            'unlocated. Each becomes a record you can edit.',
            style: TextStyle(fontFamily: Type.serif, fontSize: 15.5, height: 1.45),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 58,
            child: FilledButton.icon(
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(_reading ? 'READING…' : 'CHOOSE PHOTOS'),
              onPressed: _reading || _importing ? null : _pick,
            ),
          ),
          if (_candidates.isNotEmpty) ...[
            const SizedBox(height: 18),
            MonoLabel(
                '${_candidates.length} chosen · $located with GPS · '
                '${_candidates.length - located} without',
                size: 9,
                spacing: 1.6,
                opacity: 0.75),
            const SizedBox(height: 6),
            for (final c in _candidates)
              CheckboxListTile(
                value: c.include,
                onChanged: _importing
                    ? null
                    : (v) => setState(() => c.include = v ?? true),
                title: Text(c.file.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: MonoLabel(
                  [
                    c.located
                        ? '${c.lat!.toStringAsFixed(5)}, ${c.lng!.toStringAsFixed(5)}'
                        : 'no GPS · will be marked unlocated',
                    if (c.takenAt != null)
                      c.takenAt!.toLocal().toString().substring(0, 16),
                  ].join(' · '),
                  size: 8.5,
                  opacity: 0.75,
                ),
                secondary: SizedBox(
                  width: 44,
                  height: 44,
                  child: Image.file(File(c.file.path), fit: BoxFit.cover),
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              height: 58,
              child: FilledButton(
                onPressed: _importing || chosen == 0 ? null : _import,
                child: Text(_importing
                    ? 'IMPORTING…'
                    : 'IMPORT $chosen PHOTO${chosen == 1 ? '' : 'S'}'),
              ),
            ),
          ],
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(_status!,
                  style: const TextStyle(fontFamily: Type.serif, fontSize: 15)),
            ),
        ],
      ),
    );
  }
}
