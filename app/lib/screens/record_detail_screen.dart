import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../db/database.dart';
import '../geo/simplify.dart' show distanceM;
import '../theme/tokens.dart';
import '../widgets/press.dart';
import '../widgets/confirm.dart';
import '../widgets/edit_record_sheet.dart';

import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../geo/zone_assignment.dart';
import '../services/desk.dart';
import '../services/media_store.dart';
import '../services/observation_ops.dart' show eraseMedia;
import '../services/review.dart';
import 'identify_sheet.dart';
import 'move_pin_screen.dart';
import 'species_detail_sheet.dart';

/// Record detail (design README §3.3): photo header, title block, fact card
/// keyed by the actual schema field names — the app and the schema stay
/// honest with each other.
class RecordDetailScreen extends StatefulWidget {
  RecordDetailScreen({
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
  List<MediaData> _audio = [];
  List<(Observation, double)> _nearby = [];
  Property? _property;
  int _photoIndex = 0;
  int _zoneCount = -1;
  final _player = AudioPlayer();
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
    final zoneRows =
        await (db.select(db.zones)
              ..where((z) => z.propertyId.equals(obs.propertyId))
              ..where((z) => z.deletedAt.isNull()))
            .get();
    if (mounted) {
      setState(() {
        _review = review;
        _obs = obs;
        _taxon = taxon;
        _zone = zone;
        _env = env;
        _photos = photos;
        _audio = audio;
        _nearby = nearby.take(6).toList();
        _property = property;
        _zoneCount = zoneRows.length;
      });
    }
  }

  @override
  void dispose() {
    _player.dispose();
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

  /// Carousel arrow for the desk plate; wraps at either end.
  Widget _arrow(IconData icon, int step) => Material(
    color: Color(0xCCF7F6F2),
    shape: CircleBorder(side: BorderSide(color: Press.borderInk, width: 1)),
    child: InkWell(
      customBorder: CircleBorder(),
      onTap: () =>
          setState(() => _photoIndex = (_photoIndex + step) % _photos.length),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(icon, size: 28, color: Press.ink),
      ),
    ),
  );

  /// The photo at full size, pinch/scroll to zoom, arrows to move on.
  Future<void> _openFullSize() async {
    var index = _photoIndex;
    await showDialog<void>(
      context: context,
      barrierColor: Color(0xE61B1813),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(ctx).pop(),
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 6,
                  child: Center(
                    child: Image.file(
                      File(_photos[index].localPath!),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
            if (_photos.length > 1) ...[
              Positioned(
                left: 16,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton(
                    iconSize: 40,
                    color: Press.paper,
                    icon: Icon(Icons.chevron_left),
                    onPressed: () =>
                        setDialog(() => index = (index - 1) % _photos.length),
                  ),
                ),
              ),
              Positioned(
                right: 16,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton(
                    iconSize: 40,
                    color: Press.paper,
                    icon: Icon(Icons.chevron_right),
                    onPressed: () =>
                        setDialog(() => index = (index + 1) % _photos.length),
                  ),
                ),
              ),
            ],
            Positioned(
              top: 16,
              left: 16,
              child: IconButton(
                tooltip: 'Remove this photo',
                color: Press.paper,
                icon: Icon(Icons.delete_outline),
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await _deleteCurrentPhoto();
                },
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                color: Press.paper,
                icon: Icon(Icons.close),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() => _photoIndex = index);
  }

  /// Edit what a field ID most often gets wrong (shared editor, see
  /// widgets/edit_record_sheet.dart). MOVE THE PIN comes back here because
  /// it needs the map.
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
          // 1. Photo header — full plate with a photo, a slim bar without
          // one (a voice note or a jotted line shouldn't cost a third of
          // the screen in blank paper).
          // On a wide pane the plate is tall and the photo is shown whole on
          // paper, not cropped to a phone's strip; click it for full size.
          SizedBox(
            height:
                (_photos.isEmpty
                    ? 64
                    : widget.embedded
                    ? (MediaQuery.sizeOf(context).height * 0.6).clamp(
                        320.0,
                        760.0,
                      )
                    : 238) +
                MediaQuery.of(context).padding.top,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _photos.isNotEmpty
                    ? Container(
                        color: widget.embedded ? Press.paperEdge : null,
                        child: GestureDetector(
                          // Tap to inspect, on phone and desk alike; the
                          // full-size viewer carries the delete, visibly
                          // (design audit P2 — a hidden long-press meant
                          // "peek" sometimes offered REMOVE).
                          onTap: _openFullSize,
                          child: Image.file(
                            File(_photos[_photoIndex].localPath!),
                            fit: widget.embedded
                                ? BoxFit.contain
                                : BoxFit.cover,
                          ),
                        ),
                      )
                    : Container(color: Press.paper),
                // Desk carousel: arrows either side, every thumbnail below.
                if (widget.embedded && _photos.length > 1) ...[
                  Positioned(
                    left: 10,
                    top: 0,
                    bottom: 0,
                    child: Center(child: _arrow(Icons.chevron_left, -1)),
                  ),
                  Positioned(
                    right: 10,
                    top: 0,
                    bottom: 0,
                    child: Center(child: _arrow(Icons.chevron_right, 1)),
                  ),
                ],
                if (_photos.isNotEmpty)
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Color(0x66F4ECD8),
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!widget.embedded)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 8,
                    left: 8,
                    child: GestureDetector(
                      onTap: () {
                        final nav = Navigator.of(context);
                        if (nav.canPop()) nav.pop();
                      },
                      child: Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _photos.isEmpty
                              ? Press.paper
                              : Color(0x991B1813),
                          border: Border.all(
                            color: _photos.isEmpty
                                ? Press.ink
                                : Press.paperRaised,
                            width: 1.5,
                          ),
                        ),
                        child: Text(
                          '‹',
                          style: TextStyle(
                            fontFamily: Type.slab,
                            fontSize: 26,
                            height: 1,
                            color: _photos.isEmpty
                                ? Press.ink
                                : Press.paperRaised,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Bottom-left ink plate — a caption for the frame.
                if (_photos.isNotEmpty)
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Container(
                      color: Press.ink,
                      padding: EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      child: MonoLabel(
                        [
                          if (_photos.length > 1)
                            'Frame ${_photoIndex + 1} of ${_photos.length}',
                          if (_zone != null) _zone!.name,
                        ].join(' · '),
                        size: 8.5,
                        spacing: 1.4,
                        color: Press.paperRaised,
                      ),
                    ),
                  ),
                // Bottom-right thumbnails.
                if (_photos.length > 1)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Row(
                      children: [
                        for (
                          var i = 0;
                          i < _photos.length && (widget.embedded || i < 3);
                          i++
                        )
                          GestureDetector(
                            onTap: () => setState(() => _photoIndex = i),
                            child: Container(
                              width: widget.embedded ? 56 : 34,
                              height: widget.embedded ? 56 : 34,
                              margin: EdgeInsets.only(left: 5),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: i == _photoIndex
                                      ? Press.oxblood
                                      : Color(0xCCF4ECD8),
                                  width: i == _photoIndex ? 2 : 1,
                                ),
                                image: DecorationImage(
                                  image: FileImage(
                                    File(
                                      _photos[i].thumbPath ??
                                          _photos[i].localPath!,
                                    ),
                                  ),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
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
                      '${_taxon != null && kConfidenceLabels.containsKey(obs.taxonConfidence) ? ' · ${kConfidenceLabels[obs.taxonConfidence]}' : ''}',
                      size: 9,
                      spacing: 1.8,
                      color: typeColor,
                    ),
                  ],
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
                      if (_taxon!.nativity != null) _taxon!.nativity!,
                    ].join(' · ').toUpperCase(),
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: Press.ink,
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
                  FactRow(
                    'where',
                    obs.gpsAccuracyM == -1
                        ? 'no GPS fix — flagged, never faked'
                        : '${obs.lat.toStringAsFixed(5)}, ${obs.lng.toStringAsFixed(5)}'
                              '${obs.gpsAccuracyM != null ? '  ±${obs.gpsAccuracyM!.toStringAsFixed(0)} m' : ''}',
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
