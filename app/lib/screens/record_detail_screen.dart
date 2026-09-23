import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../db/database.dart';
import '../geo/simplify.dart' show distanceM;
import '../theme/tokens.dart';
import '../widgets/photo_gallery.dart';
import '../widgets/press.dart';
import '../widgets/condition_log_dialog.dart';
import '../widgets/confirm.dart';
import '../widgets/edit_record_sheet.dart';
import '../widgets/edit_sheet.dart';
import '../widgets/nativity_chip.dart';
import '../widgets/removal_chip.dart';

import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../geo/zone_assignment.dart';
import '../services/desk.dart';
import '../services/record_filter.dart';
import '../services/media_store.dart';
import '../services/observation_ops.dart' show eraseMedia;
import '../services/review.dart';
import 'identify_sheet.dart';
import 'move_pin_screen.dart';
import '../protocols/indicators.dart';
import '../protocols/protocol_service.dart';
import 'monitoring/run_summary_card.dart';
import 'monitoring/site_detail_screen.dart';
import 'photo_points/photo_point_history_screen.dart';
import 'species_detail_sheet.dart';

/// Record detail (design README §3.3): photo header, title block, fact card
/// keyed by the actual schema field names — the app and the schema stay
/// honest with each other.
class RecordDetailScreen extends StatefulWidget {
  const RecordDetailScreen({
    super.key,
    required this.db,
    required this.obsId,
    this.embedded = false,
  });

  final FieldNotesDb db;
  final String obsId;

  /// Living inside the desk's pane (D-024): no back chip, and the photo
  /// header fits the photo rather than cropping it to a phone plate.
  final bool embedded;

  @override
  State<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

class _RecordDetailScreenState extends State<RecordDetailScreen> {
  Observation? _obs;
  bool _gone = false;
  TaxaData? _taxon;
  Zone? _zone;
  EnvContext? _env;
  ReviewItem? _review;
  List<MediaData> _photos = [];

  /// The station this record's photo anchors, if it became one.
  PhotoPoint? _photoPoint;

  /// The monitoring run this record was made as (D-033), if it was one.
  ProtocolRun? _run;
  Protocol? _runProtocol;
  ProtocolSite? _runSite;
  List<Indicator> _runIndicators = const [];
  List<MediaData> _audio = [];
  List<(Observation, double)> _nearby = [];
  Property? _property;
  int _photoIndex = 0;
  int _zoneCount = -1;
  // Lazy: the audio engine exists only once a voice note actually
  // plays — a record with no recording must not spin one up (and the
  // desk test host has no audio plugin at all). Audit 2026-09-05.
  AudioPlayer? _playerInstance;
  AudioPlayer get _player => _playerInstance ??= AudioPlayer();
  String? _playingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.db;
    final obs = await (db.select(
      db.observations,
    )..where((o) => o.id.equals(widget.obsId))).getSingleOrNull();
    if (obs == null) {
      if (mounted) setState(() => _gone = true);
      return;
    }
    final property = await (db.select(
      db.properties,
    )..where((p) => p.id.equals(obs.propertyId))).getSingleOrNull();
    TaxaData? taxon;
    if (obs.taxonId != null) {
      taxon = await (db.select(
        db.taxa,
      )..where((t) => t.id.equals(obs.taxonId!))).getSingleOrNull();
    }
    Zone? zone;
    if (obs.zoneId != null) {
      zone = await (db.select(
        db.zones,
      )..where((z) => z.id.equals(obs.zoneId!))).getSingleOrNull();
    }
    EnvContext? env;
    if (obs.envContextId != null) {
      env = await (db.select(
        db.envContexts,
      )..where((e) => e.id.equals(obs.envContextId!))).getSingleOrNull();
    }
    final links =
        await (db.select(db.mediaLinks)
              ..where(
                (l) =>
                    l.entityType.equals('observation') &
                    l.entityId.equals(obs.id) &
                    l.deletedAt.isNull(),
              )
              ..orderBy([(l) => OrderingTerm.asc(l.sortOrder)]))
            .get();
    final photos = <MediaData>[];
    final audio = <MediaData>[];
    for (final link in links) {
      final m = await (db.select(
        db.media,
      )..where((x) => x.id.equals(link.mediaId))).getSingleOrNull();
      if (m == null ||
          m.localPath == null ||
          !File(m.localPath!).existsSync()) {
        continue;
      }
      if (m.mediaType == 'audio') {
        audio.add(m);
      } else {
        photos.add(m);
      }
    }
    // Related (spec §7.4): other records within 50 m — the same plant
    // photographed again, the same spring checked again.
    final nearby = <(Observation, double)>[];
    if (obs.gpsAccuracyM != -1) {
      final candidates =
          await (db.select(db.observations)
                ..where((o) => o.propertyId.equals(obs.propertyId))
                ..where((o) => o.deletedAt.isNull())
                ..where((o) => o.id.equals(obs.id).not())
                ..where(
                  (o) =>
                      o.gpsAccuracyM.equals(-1).not() | o.gpsAccuracyM.isNull(),
                )
                ..where(
                  (o) =>
                      o.lat.isBetweenValues(obs.lat - 0.001, obs.lat + 0.001),
                )
                ..where(
                  (o) =>
                      o.lng.isBetweenValues(obs.lng - 0.001, obs.lng + 0.001),
                ))
              .get();
      for (final c in candidates) {
        final d = distanceM([obs.lng, obs.lat], [c.lng, c.lat]);
        if (d <= 50) nearby.add((c, d));
      }
      nearby.sort((a, b) => a.$2.compareTo(b.$2));
    }
    final review = await ReviewService(widget.db)
        .forEntity('observation', widget.obsId);
    final photoPoint = photos.isEmpty
        ? null
        : await (db.select(db.photoPoints)
                ..where(
                  (p) =>
                      p.referenceMediaId.isIn([for (final m in photos) m.id]),
                )
                ..where((p) => p.deletedAt.isNull())
                ..limit(1))
              .getSingleOrNull();
    final zoneRows =
        await db.zonesOf(obs.propertyId);
    ProtocolRun? run;
    Protocol? runProtocol;
    ProtocolSite? runSite;
    var runIndicators = const <Indicator>[];
    if (obs.observationType == 'survey') {
      final svc = ProtocolService(db);
      run = await svc.runForObservation(obs.id);
      if (run != null) {
        runProtocol = await (db.select(
          db.protocols,
        )..where((p) => p.id.equals(run!.protocolId))).getSingleOrNull();
        runSite = await (db.select(
          db.protocolSites,
        )..where((s) => s.id.equals(run!.siteId))).getSingleOrNull();
        if (runProtocol != null && runSite != null) {
          runIndicators = await svc.indicatorsFor(runProtocol, runSite, run);
        }
      }
    }
    if (mounted) {
      setState(() {
        _run = run;
        _runProtocol = runProtocol;
        _runSite = runSite;
        _runIndicators = runIndicators;
        _review = review;
        _obs = obs;
        _taxon = taxon;
        _zone = zone;
        _env = env;
        _photos = photos;
        _photoPoint = photoPoint;
        _audio = audio;
        _nearby = nearby.take(6).toList();
        _property = property;
        _zoneCount = zoneRows.length;
      });
    }
  }

  @override
  void dispose() {
    _playerInstance?.dispose();
    super.dispose();
  }

  String _fmtDate(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _fmtMs(int? ms) {
    if (ms == null) return 'play';
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _play(MediaData a) async {
    if (_playingId == a.id) {
      await _player.stop();
      if (mounted) setState(() => _playingId = null);
      return;
    }
    try {
      await _player.stop();
      _player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _playingId = null);
      });
      await _player.play(DeviceFileSource(a.localPath!));
      if (mounted) setState(() => _playingId = a.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not play: $e')));
      }
    }
  }

  /// Remove ONE picture from this record (Austin, 2026-09-01). The link
  /// goes first; the file itself is erased only when no other record still
  /// uses it (photos are content-deduplicated across records).
  Future<void> _deleteCurrentPhoto() async {
    final obs = _obs;
    if (obs == null || _photos.isEmpty) return;
    final media = _photos[_photoIndex];
    final sure = await confirmDialog(
      context,
      title: 'REMOVE THIS PHOTO?',
      body: _photos.length == 1
          ? 'The record keeps its facts and notes; its only photo goes.'
          : 'Photo ${_photoIndex + 1} of ${_photos.length} comes off '
                'this record.',
      cancelLabel: 'KEEP',
      confirmLabel: 'REMOVE',
    );
    if (!sure) return;
    await (widget.db.delete(widget.db.mediaLinks)..where(
          (l) =>
              l.mediaId.equals(media.id) &
              l.entityType.equals('observation') &
              l.entityId.equals(obs.id),
        ))
        .go();
    final remaining = await (widget.db.select(
      widget.db.mediaLinks,
    )..where((l) => l.mediaId.equals(media.id) & l.deletedAt.isNull())).get();
    if (remaining.isEmpty) {
      await eraseMedia(widget.db, media.id);
    }
    _photoIndex = 0;
    await _load();
  }

  Future<void> _addPhotos() async {
    final obs = _obs;
    if (obs == null) return;
    final picker = ImagePicker();
    List<XFile> picked = [];
    try {
      if (isDesk) {
        picked = await picker.pickMultiImage();
      } else {
        final source = await showModalBottomSheet<ImageSource>(
          context: context,
          backgroundColor: Press.paper,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take a photo'),
                  onTap: () => Navigator.pop(ctx, ImageSource.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Choose from gallery'),
                  onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
        if (source == null) return;
        if (source == ImageSource.camera) {
          final one = await picker.pickImage(source: source, imageQuality: 92);
          if (one != null) picked = [one];
        } else {
          picked = await picker.pickMultiImage(imageQuality: 92);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open photos: $e')));
      }
      return;
    }
    if (picked.isEmpty) return;
    final store = MediaStore(widget.db);
    for (final x in picked) {
      final media = await store.savePhoto(
        await x.readAsBytes(),
        propertyId: obs.propertyId,
        createdBy: 'local',
        capturedAt: nowUtcIso(),
      );
      await store.linkTo(
        media.id,
        propertyId: obs.propertyId,
        entityType: 'observation',
        entityId: obs.id,
        role: _photos.isEmpty ? 'primary' : 'attachment',
      );
    }
    await _load();
  }


  /// Edit what a field ID most often gets wrong (shared editor, see
  /// widgets/edit_record_sheet.dart). MOVE THE PIN comes back here because
  /// it needs the map.
  static const _conditions = [
    ('good', 'Good'),
    ('fair', 'Fair'),
    ('poor', 'Poor'),
    ('critical', 'Critical'),
    ('unknown', 'Unknown'),
  ];

  Future<void> _editConditionLog(ConditionLog l) async {
    final r = await showEditSheet(
      context,
      title: 'Edit condition',
      fields: [
        DateEdit('on', 'Observed on', initial: l.observedAt),
        ChoiceEdit(
          'condition',
          'Condition',
          options: _conditions,
          initial: l.condition,
        ),
        TextEdit('action', 'Action taken', initial: l.actionTaken),
        TextEdit('notes', 'Notes', initial: l.notes, lines: 2),
      ],
      deleteTitle: 'DELETE THIS CONDITION ENTRY?',
    );
    if (r == null) return;
    final now = nowUtcIso();
    final q = widget.db.update(widget.db.conditionLogs)
      ..where((x) => x.id.equals(l.id));
    if (r.deleted) {
      await q.write(
        ConditionLogsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
      return;
    }
    await q.write(
      ConditionLogsCompanion(
        observedAt: Value(withDay(l.observedAt, r.day('on') ?? l.observedAt)),
        condition: Value(r.text('condition') ?? l.condition),
        actionTaken: Value(r.text('action')),
        notes: Value(r.text('notes')),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> _makePhotoPoint() async {
    final obs = _obs!;
    final now = nowUtcIso();
    final name =
        _taxon?.commonName ??
        _taxon?.scientificName ??
        'Photo point ${obs.observedAt.substring(0, 10)}';
    final heading = obs.headingDeg;
    await widget.db
        .into(widget.db.photoPoints)
        .insert(
          PhotoPointsCompanion.insert(
            id: newId(),
            propertyId: obs.propertyId,
            name: name,
            lat: obs.lat,
            lng: obs.lng,
            bearingDeg: heading != null && heading >= 0 ? heading : 0,
            subject: Value(_taxon?.commonName ?? _taxon?.scientificName),
            cadenceDays: const Value(90),
            focalLengthMm: const Value(26),
            viewExtentM: const Value(60),
            referenceMediaId: Value(_photos.first.id),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('PHOTO POINT · $name — find it under Photo points'),
      ),
    );
    _load();
  }

  Future<void> _setRemoval(String? status) async {
    final now = nowUtcIso();
    await (widget.db.update(
      widget.db.observations,
    )..where((o) => o.id.equals(widget.obsId))).write(
      ObservationsCompanion(
        removalStatus: Value(status),
        removedOn: Value(status == 'removed' ? now.substring(0, 10) : null),
        updatedAt: Value(now),
      ),
    );
    _load();
  }

  Future<void> _editRecord() async {
    final obs = _obs;
    if (obs == null) return;
    final outcome = await showEditRecordSheet(
      context,
      db: widget.db,
      obs: obs,
      taxon: _taxon,
      // The pin moves on a map, and the desk has none yet.
      allowMovePin: !isDesk,
    );
    if (!mounted) return;
    if (outcome == EditOutcome.movePin) {
      await _movePin(obs);
      return;
    }
    if (outcome == EditOutcome.saved) _load();
  }

  /// Hand-adjust the record's location, then keep the derived facts honest:
  /// accuracy becomes "placed by hand" (null — the same meaning the capture
  /// flow gives a map-drop), and the zone is re-derived from the new point,
  /// including clearing it when the pin moves outside every zone.
  Future<void> _movePin(Observation obs) async {
    final moved = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => MovePinScreen(lat: obs.lat, lng: obs.lng),
      ),
    );
    if (moved == null) return;
    await (widget.db.update(
      widget.db.observations,
    )..where((o) => o.id.equals(obs.id))).write(
      ObservationsCompanion(
        lat: Value(moved.latitude),
        lng: Value(moved.longitude),
        gpsAccuracyM: const Value(null),
        zoneId: const Value(null),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    await assignZone(
      widget.db,
      observationId: obs.id,
      propertyId: obs.propertyId,
      lat: moved.latitude,
      lng: moved.longitude,
    );
    _load();
  }

  Future<void> _delete() async {
    final confirmed = await confirmDialog(
      context,
      title: 'DELETE RECORD?',
      body: 'The record leaves your ledger. Photos stay on disk.',
      confirmLabel: 'DELETE',
    );
    if (!confirmed) return;
    // Soft delete (spec §4.1) — sync engines need tombstones.
    await (widget.db.update(
      widget.db.observations,
    )..where((o) => o.id.equals(widget.obsId))).write(
      ObservationsCompanion(
        deletedAt: Value(nowUtcIso()),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (!widget.embedded && nav.canPop()) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final obs = _obs;
    if (obs == null) {
      return Scaffold(
        appBar: widget.embedded ? null : AppBar(),
        body: Center(
          child: _gone
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'This record is gone from the ledger — removed here or '
                    'on another device.',
                    textAlign: TextAlign.center,
                  ),
                )
              : const CircularProgressIndicator(),
        ),
      );
    }
    final typeColor = recordTypeColor(obs.observationType);
    // observed_at is stored UTC (spec §4); show it in the phone's local time
    // so the label (local_tz) and the digits agree.
    final parsed = DateTime.tryParse(obs.observedAt)?.toLocal();
    final when = parsed == null
        ? obs.observedAt
        : '${parsed.year.toString().padLeft(4, '0')}-'
              '${parsed.month.toString().padLeft(2, '0')}-'
              '${parsed.day.toString().padLeft(2, '0')} '
              '${parsed.hour.toString().padLeft(2, '0')}:'
              '${parsed.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          // 1. Photographs. Sized to the picture's own shape inside the
          // space available — never cropped, never enlarged past its pixels.
          // A record with no photo gets a slim bar instead of a third of the
          // screen in blank paper.
          if (_photos.isEmpty)
            SizedBox(height: 64 + MediaQuery.of(context).padding.top)
          else
            Padding(
              padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
              child: PhotoPlate(
                photos: [for (final m in _photos) m.localPath!],
                index: _photoIndex.clamp(0, _photos.length - 1),
                onIndex: (i) => setState(() => _photoIndex = i),
                onDelete: (i) {
                  setState(() => _photoIndex = i);
                  _deleteCurrentPhoto();
                },
                maxHeight: widget.embedded ? 620 : 460,
              ),
            ),
          // 2. Title block.
          Padding(
            padding: EdgeInsets.fromLTRB(Metrics.gutter, 14, Metrics.gutter, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(width: 14, height: 2, color: Press.oxblood),
                    SizedBox(width: 7),
                    MonoLabel(
                      '${obs.observationType}'
                      '${_taxon != null && kConfidenceLabels.containsKey(obs.taxonConfidence) ? ' · ${kConfidenceLabels[obs.taxonConfidence]}' : ''}'
                      // the zone used to ride on the photo overlay; it belongs
                      // with the record's other facts, not on the picture
                      '${_zone != null ? ' · ${_zone!.name}' : ''}',
                      size: 9,
                      spacing: 1.8,
                      color: typeColor,
                    ),
                  ],
                ),
                if (obs.removalStatus != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: RemovalChip(
                        obs.removalStatus,
                        removedOn: obs.removedOn,
                      ),
                    ),
                  ),
                SizedBox(height: 8),
                if (_taxon != null) ...[
                  // Name → the species' whole history on this place.
                  GestureDetector(
                    onTap: _property == null
                        ? null
                        : () => showSpeciesDetailSheet(
                            context,
                            db: widget.db,
                            property: _property!,
                            taxon: _taxon!,
                          ),
                    child: TaxonName(_taxon!.scientificName, size: 34),
                  ),
                  SizedBox(height: 5),
                  Text(
                    [
                      if (_taxon!.commonName != null) _taxon!.commonName!,
                      if (_taxon!.family != null) _taxon!.family!,
                    ].join(' · ').toUpperCase(),
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: Press.ink,
                    ),
                  ),
                  if (_taxon!.nativity != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: NativityChip(_taxon!.nativity),
                      ),
                    ),
                ] else
                  Text(
                    obs.observationType.toUpperCase(),
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w900,
                      fontSize: 30,
                      height: 0.9,
                      color: Press.ink,
                    ),
                  ),
                // Pending-visible review (SYNC-DESIGN): the tag rides the
                // record so a contributor's edit is never mistaken for a
                // settled fact — and never hidden either.
                if (_review != null && _review!.state == 'pending') ...[
                  SizedBox(height: 8),
                  StatusPill('pending review', color: Press.ochre),
                ],
              ],
            ),
          ),

          // 3. Fact card — schema field names as keys.
          Padding(
            padding: EdgeInsets.all(Metrics.gutter),
            child: Container(
              decoration: BoxDecoration(
                color: Press.paperRaised,
                border: Border.all(color: Press.borderInk, width: 1.5),
              ),
              child: Column(
                children: [
                  FactRow('when', '$when ${obs.localTz}'),
                  InkWell(
                    // Tap the place line → the map, showing ONLY this
                    // species (Austin, 2026-09-04). No species: no jump.
                    onTap: obs.taxonId == null || obs.gpsAccuracyM == -1
                        ? null
                        : () {
                            recordFilter.update((f) {
                              f.taxonId = obs.taxonId;
                              f.taxonLabel =
                                  _taxon?.commonName ??
                                  _taxon?.scientificName ??
                                  'species';
                            });
                            recordFilter.jumpToMap();
                            if (!widget.embedded) {
                              Navigator.of(context).popUntil((r) => r.isFirst);
                            }
                          },
                    child: FactRow(
                      'where',
                      obs.gpsAccuracyM == -1
                          ? 'no GPS fix — flagged, never faked'
                          : '${obs.lat.toStringAsFixed(5)}, ${obs.lng.toStringAsFixed(5)}'
                                '${obs.gpsAccuracyM != null ? '  ±${obs.gpsAccuracyM!.toStringAsFixed(0)} m' : ''}'
                                '${obs.taxonId != null ? '  ·  ⌖ all on map' : ''}',
                    ),
                  ),
                  FactRow('zone', _zone?.name ?? noZoneLabel(_zoneCount)),
                  if (_env != null) ...[
                    FactRow(
                      'rain, 30 d',
                      // True whether the lookup is switched off or simply
                      // hasn't run yet — the old copy promised a lookup that
                      // may never happen now that it's opt-in (D-022).
                      _env!.isStale == 1
                          ? 'not looked up'
                          : '${_env!.precip30dMm?.toStringAsFixed(1) ?? '—'} mm · '
                                '${_env!.daysSinceRain ?? '—'} d since rain',
                    ),
                    if (_env!.soilSeries != null)
                      FactRow(
                        'soil',
                        [
                          _env!.soilSeries!,
                          if (_env!.soilDrainageClass != null)
                            _env!.soilDrainageClass!,
                        ].join(' · '),
                      ),
                  ],
                  if (_photos.isNotEmpty)
                    FactRow(
                      'photos',
                      '${_photos.length} · on this phone only',
                      last: _audio.isEmpty,
                    ),
                  if (_audio.isNotEmpty)
                    FactRow(
                      'voice',
                      '${_audio.length} note${_audio.length == 1 ? '' : 's'} · on this phone only',
                      last: true,
                    ),
                  if (_photos.isEmpty && _audio.isEmpty)
                    FactRow('media', 'none', last: true),
                ],
              ),
            ),
          ),

          // Condition — the merged feature timeline (2026-09-04): a spring,
          // a gate, a diseased oak — any record can carry one.
          Padding(
            padding: EdgeInsets.fromLTRB(Metrics.gutter, 0, Metrics.gutter, 14),
            child: StreamBuilder<List<ConditionLog>>(
              stream:
                  (widget.db.select(widget.db.conditionLogs)
                        ..where((l) => l.observationId.equals(obs.id))
                        ..where((l) => l.deletedAt.isNull())
                        ..orderBy([(l) => OrderingTerm.desc(l.observedAt)]))
                      .watch(),
              builder: (context, snapshot) {
                final logs = snapshot.data ?? const <ConditionLog>[];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        // Kicker stretches its rule with an Expanded; as a
                        // plain Row child its width is unbounded and layout
                        // throws — every record with this section red-screens
                        // (audit 2026-09-05). Give it the bounded slot.
                        Expanded(child: Kicker('Condition')),
                        if (logs.isNotEmpty)
                          StatusPill(
                            logs.first.condition.toUpperCase(),
                            color: conditionColor(logs.first.condition),
                            filled: true,
                          ),
                      ],
                    ),
                    SizedBox(height: 6),
                    for (final l in logs)
                      InkWell(
                        onTap: () => _editConditionLog(l),
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Diamond(
                                size: 10,
                                color: conditionColor(l.condition),
                                filled: true,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  [
                                    '${l.observedAt.substring(0, 10)} · '
                                        '${l.condition}',
                                    if (l.actionTaken != null) l.actionTaken!,
                                    if (l.notes != null) l.notes!,
                                  ].join(' · '),
                                  style: TextStyle(
                                    fontFamily: Type.serif,
                                    fontSize: 14.5,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    SizedBox(height: 4),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton(
                        onPressed: () => showConditionLogDialog(
                          context,
                          db: widget.db,
                          obs: obs,
                        ),
                        child: Text('LOG CONDITION'),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

          // Notes.
          if (obs.notes != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                14,
              ),
              child: Text(
                obs.notes!,
                style: TextStyle(
                  fontFamily: Type.serif,
                  fontSize: 16,
                  height: 1.5,
                ),
              ),
            ),

          // 5. Voice notes — the audio is the record; the transcript is
          // already in the notes above.
          for (final a in _audio)
            Padding(
              padding: EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                12,
              ),
              child: SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  icon: Icon(
                    _playingId == a.id ? Icons.stop : Icons.play_arrow,
                  ),
                  label: Text(
                    _playingId == a.id
                        ? 'STOP'
                        : 'VOICE NOTE · ${_fmtMs(a.durationMs)}',
                  ),
                  onPressed: () => _play(a),
                ),
              ),
            ),

          // 5b. Related: other records within 50 m (spec §7.4) — the return
          // visit is the whole point (core principle 4).
          if (_nearby.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                Metrics.gutter,
                4,
                Metrics.gutter,
                14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MonoLabel('Nearby · within 50 m', size: 9, spacing: 1.8),
                  const SizedBox(height: 4),
                  for (final (o, d) in _nearby)
                    InkWell(
                      onTap: () => Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) =>
                              RecordDetailScreen(db: widget.db, obsId: o.id),
                        ),
                      ),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 52),
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Press.divider, width: 1),
                          ),
                        ),
                        child: Row(
                          children: [
                            Diamond(
                              size: 7,
                              color: recordTypeColor(o.observationType),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                [
                                  _fmtDate(o.observedAt),
                                  o.observationType,
                                  if (o.notes != null) o.notes!,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: Type.serif,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            MonoLabel(
                              '${d.toStringAsFixed(0)} m',
                              size: 9,
                              opacity: 0.7,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // 5c. Identify: only where there's a photograph to work from.
          if (_photos.isNotEmpty && _property != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                12,
              ),
              child: SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.eco_outlined),
                  label: Text(
                    _taxon == null ? 'WHAT IS IT?' : 'SUGGEST ANOTHER SPECIES',
                  ),
                  onPressed: () async {
                    final accepted = await showIdentifySheet(
                      context,
                      db: widget.db,
                      observation: _obs!,
                      property: _property!,
                      // Every photo of the record goes to Pl@ntNet (up to five).
                      photos: [for (final p in _photos) File(p.localPath!)],
                    );
                    if (accepted) _load();
                  },
                ),
              ),
            ),

          // Photos can be added after the fact — from the camera on the
          // phone, from files on the desk — without pretending they were
          // taken where the record was.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Metrics.gutter,
              0,
              Metrics.gutter,
              12,
            ),
            child: SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add_a_photo_outlined),
                label: const Text('ADD PHOTOS'),
                onPressed: _addPhotos,
              ),
            ),
          ),

          // A species record can become a station (Austin, 2026-09-07:
          // "each species record should also have a photo pts option"):
          // same spot, same aim, the record's photo as the anchor frame.
          if (_photos.isNotEmpty && obs.gpsAccuracyM != -1)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                12,
              ),
              child: SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  icon: Icon(
                    _photoPoint == null
                        ? Icons.center_focus_weak
                        : Icons.center_focus_strong,
                  ),
                  label: Text(
                    _photoPoint == null
                        ? 'MAKE A PHOTO POINT'
                        : 'PHOTO POINT ✓ · OPEN',
                  ),
                  onPressed: _photoPoint == null
                      ? _makePhotoPoint
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PhotoPointHistoryScreen(
                              db: widget.db,
                              point: _photoPoint!,
                            ),
                          ),
                        ),
                ),
              ),
            ),

          // Monitoring (D-033): the run this record was made as — the
          // method, the site, and what the answers add up to.
          if (_run != null && _runProtocol != null && _runSite != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                12,
              ),
              child: RunSummaryCard(
                protocol: _runProtocol!,
                site: _runSite!,
                run: _run!,
                indicators: _runIndicators,
                onOpenSite: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SiteDetailScreen(
                      db: widget.db,
                      protocol: _runProtocol!,
                      site: _runSite!,
                    ),
                  ),
                ),
              ),
            ),

          // Removal (D-027): flag it, then say when it came out. Pulling
          // ashe juniper, mesquite and chinaberry is restoration work as
          // much as planting is (Austin, 2026-09-07).
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Metrics.gutter,
              0,
              Metrics.gutter,
              12,
            ),
            child: switch (obs.removalStatus) {
              null => SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Press.oxblood,
                    side: BorderSide(color: Press.oxblood, width: 1.5),
                  ),
                  icon: const Icon(Icons.content_cut),
                  label: const Text('FLAG FOR REMOVAL'),
                  onPressed: () => _setRemoval('flagged'),
                ),
              ),
              'flagged' => Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Press.oxblood,
                        ),
                        icon: const Icon(Icons.check),
                        label: const Text('MARK REMOVED'),
                        onPressed: () => _setRemoval('removed'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 56,
                    child: OutlinedButton(
                      onPressed: () => _setRemoval(null),
                      child: const Text('CLEAR FLAG'),
                    ),
                  ),
                ],
              ),
              _ => SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.undo),
                  label: Text(
                    'REMOVED${obs.removedOn != null ? ' ${obs.removedOn}' : ''} · REOPEN',
                  ),
                  onPressed: () => _setRemoval('flagged'),
                ),
              ),
            },
          ),

          // 6. Actions.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Metrics.gutter,
              0,
              Metrics.gutter,
              24,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: FilledButton(
                      onPressed: _editRecord,
                      child: const Text('EDIT'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: _delete,
                    child: const Text('DELETE'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
