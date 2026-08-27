import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../geo/simplify.dart' show distanceM;
import '../theme/tokens.dart';
import '../widgets/press.dart';
import '../widgets/species_field.dart';
import 'species_detail_sheet.dart';

const _kTypes = [
  'general',
  'plant',
  'wildlife',
  'problem',
  'water',
  'soil',
  'phenology',
  'sign',
  'weather',
  'maintenance',
];

const _kConfidence = {
  'certain': 'Certain',
  'probable': 'Probably',
  'uncertain': 'Not sure',
};

/// Record detail (design README §3.3): photo header, title block, fact card
/// keyed by the actual schema field names — the app and the schema stay
/// honest with each other.
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
  EnvContext? _env;
  List<MediaData> _photos = const [];
  List<MediaData> _audio = const [];
  List<(Observation, double)> _nearby = const [];
  Property? _property;
  int _photoIndex = 0;
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
    if (obs == null) return;
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
    if (mounted) {
      setState(() {
        _obs = obs;
        _taxon = taxon;
        _zone = zone;
        _env = env;
        _photos = photos;
        _audio = audio;
        _nearby = nearby.take(6).toList();
        _property = property;
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

  /// Edit what a field ID most often gets wrong: the species, the kind of
  /// record, how sure you were, and the notes. Location and time are the
  /// record's evidence and stay as captured.
  Future<void> _editRecord() async {
    final obs = _obs;
    if (obs == null) return;
    final notes = TextEditingController(text: obs.notes ?? '');
    TaxaData? taxon = _taxon;
    var type = obs.observationType;
    String? confidence = obs.taxonConfidence;
    if (confidence == 'unidentified') confidence = null;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Press.paper,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            // Keep the keyboard clear, and stay out from under the clock.
            top: MediaQuery.of(ctx).padding.top + 8,
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SafeArea(
            top: false,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(Metrics.gutter),
              children: [
                const MonoLabel('Edit record', size: 10, spacing: 2),
                const SizedBox(height: 12),
                SpeciesField(
                  db: widget.db,
                  label: 'Species — common or Latin name',
                  initial: taxon,
                  onSelected: (t) => setSheet(() {
                    taxon = t;
                    if (t == null) confidence = null;
                    // Same default the capture flow writes: naming it from
                    // the list counts as certain until you say otherwise.
                    if (t != null && confidence == null) confidence = 'certain';
                    if (t != null && type == 'general') type = 'plant';
                  }),
                ),
                if (taxon != null) ...[
                  const SizedBox(height: 12),
                  const MonoLabel('How sure?', size: 9, spacing: 1.8),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final e in _kConfidence.entries)
                        _pill(
                          e.value,
                          confidence == e.key,
                          () => setSheet(() => confidence = e.key),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                const MonoLabel('What kind of record', size: 9, spacing: 1.8),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final t in _kTypes)
                      _pill(
                        t.toUpperCase(),
                        type == t,
                        () => setSheet(() => type = t),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                const MonoLabel('Notes', size: 9, spacing: 1.8),
                const SizedBox(height: 6),
                TextField(
                  controller: notes,
                  minLines: 3,
                  maxLines: 8,
                  textCapitalization: TextCapitalization.sentences,
                  cursorColor: Press.oxblood,
                  style: const TextStyle(
                    fontFamily: Type.serif,
                    fontSize: 16,
                    height: 1.5,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'What did you see?',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('SAVE CHANGES'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 52,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('CANCEL'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final text = notes.text.trim();
    notes.dispose();
    if (saved != true) return;
    await (widget.db.update(
      widget.db.observations,
    )..where((o) => o.id.equals(obs.id))).write(
      ObservationsCompanion(
        taxonId: Value(taxon?.id),
        taxonConfidence: Value(taxon == null ? 'unidentified' : confidence),
        observationType: Value(type),
        notes: Value(text.isEmpty ? null : text),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    _load();
  }

  Widget _pill(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56, // glove target (spec §7)
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: on ? Press.ink : null,
          border: Border.all(color: Press.ink, width: 1),
          borderRadius: BorderRadius.circular(999),
        ),
        // Center(widthFactor) keeps the pill hugging its label inside a Wrap.
        child: Center(
          widthFactor: 1,
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: Type.mono,
              fontSize: 9.5,
              letterSpacing: 1.4,
              color: on ? Press.paper : Press.ink,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('DELETE RECORD?'),
        content: const Text(
          'The record leaves your ledger. Photos stay on disk.',
          style: TextStyle(fontFamily: Type.serif, fontSize: 15.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Soft delete (spec §4.1) — sync engines need tombstones.
    await (widget.db.update(
      widget.db.observations,
    )..where((o) => o.id.equals(widget.obsId))).write(
      ObservationsCompanion(
        deletedAt: Value(nowUtcIso()),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final obs = _obs;
    if (obs == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
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
          SizedBox(
            height:
                (_photos.isEmpty ? 64 : 238) +
                MediaQuery.of(context).padding.top,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _photos.isNotEmpty
                    ? Image.file(
                        File(_photos[_photoIndex].localPath!),
                        fit: BoxFit.cover,
                      )
                    : Container(color: Press.paper),
                if (_photos.isNotEmpty)
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: const Color(0x66F4ECD8),
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 8,
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 56,
                      height: 56,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _photos.isEmpty
                            ? Press.paper
                            : const Color(0x991B1813),
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
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
                        for (var i = 0; i < _photos.length && i < 3; i++)
                          GestureDetector(
                            onTap: () => setState(() => _photoIndex = i),
                            child: Container(
                              width: 34,
                              height: 34,
                              margin: const EdgeInsets.only(left: 5),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: i == _photoIndex
                                      ? Press.oxblood
                                      : const Color(0xCCF4ECD8),
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
            padding: const EdgeInsets.fromLTRB(
              Metrics.gutter,
              14,
              Metrics.gutter,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(width: 14, height: 2, color: Press.oxblood),
                    const SizedBox(width: 7),
                    MonoLabel(
                      '${obs.observationType}'
                      '${_taxon != null && _kConfidence.containsKey(obs.taxonConfidence) ? ' · ${_kConfidence[obs.taxonConfidence]}' : ''}',
                      size: 9,
                      spacing: 1.8,
                      color: typeColor,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
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
                  const SizedBox(height: 5),
                  Text(
                    [
                      if (_taxon!.commonName != null) _taxon!.commonName!,
                      if (_taxon!.family != null) _taxon!.family!,
                      if (_taxon!.nativity != null) _taxon!.nativity!,
                    ].join(' · ').toUpperCase(),
                    style: const TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: Press.ink,
                    ),
                  ),
                ] else
                  Text(
                    obs.observationType.toUpperCase(),
                    style: const TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w900,
                      fontSize: 30,
                      height: 0.9,
                      color: Press.ink,
                    ),
                  ),
              ],
            ),
          ),

          // 3. Fact card — schema field names as keys.
          Padding(
            padding: const EdgeInsets.all(Metrics.gutter),
            child: Container(
              decoration: BoxDecoration(
                color: Press.paperRaised,
                border: Border.all(color: Press.ink, width: 1.5),
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
                  FactRow(
                    'zone',
                    _zone != null ? _zone!.name : 'outside any zone',
                  ),
                  if (_env != null) ...[
                    FactRow(
                      'rain, 30 d',
                      _env!.isStale == 1
                          ? 'looked up when back online'
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
                    const FactRow('media', 'none', last: true),
                ],
              ),
            ),
          ),

          // Notes.
          if (obs.notes != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Metrics.gutter,
                0,
                Metrics.gutter,
                14,
              ),
              child: Text(
                obs.notes!,
                style: const TextStyle(
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
              padding: const EdgeInsets.fromLTRB(
                Metrics.gutter,
                4,
                Metrics.gutter,
                14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MonoLabel(
                    'Nearby · within 50 m',
                    size: 9,
                    spacing: 1.8,
                  ),
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
                        decoration: const BoxDecoration(
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
                                style: const TextStyle(
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
