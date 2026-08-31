import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../theme/tokens.dart';
import '../../widgets/press.dart';
import 'ghost_capture_screen.dart';

/// Photo point history (spec §7.8 "time-series scrubber"): every visit's
/// frame in date order, a slider to move through them, the anchor frame
/// beside the current one so change reads at a glance.
class PhotoPointHistoryScreen extends StatefulWidget {
  const PhotoPointHistoryScreen(
      {super.key, required this.db, required this.point});

  final FieldNotesDb db;
  final PhotoPoint point;

  @override
  State<PhotoPointHistoryScreen> createState() =>
      _PhotoPointHistoryScreenState();
}

class _Frame {
  _Frame(this.visit, this.media);
  final PhotoPointVisit visit;
  final MediaData media;
}

class _PhotoPointHistoryScreenState extends State<PhotoPointHistoryScreen> {
  List<_Frame> _frames = const [];
  int _index = 0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.db;
    final visits = await (db.select(db.photoPointVisits)
          ..where((v) => v.photoPointId.equals(widget.point.id))
          ..where((v) => v.deletedAt.isNull())
          ..orderBy([(v) => OrderingTerm.asc(v.visitedAt)]))
        .get();
    final frames = <_Frame>[];
    for (final v in visits) {
      final link = await (db.select(db.mediaLinks)
            ..where((l) =>
                l.entityType.equals('photo_point_visit') &
                l.entityId.equals(v.id) &
                l.deletedAt.isNull())
            ..limit(1))
          .getSingleOrNull();
      if (link == null) continue;
      final m = await (db.select(db.media)
            ..where((x) => x.id.equals(link.mediaId)))
          .getSingleOrNull();
      if (m?.localPath != null && File(m!.localPath!).existsSync()) {
        frames.add(_Frame(v, m));
      }
    }
    if (mounted) {
      setState(() {
        _frames = frames;
        _index = frames.isEmpty ? 0 : frames.length - 1;
        _loaded = true;
      });
    }
  }

  String _date(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return iso;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _capture() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GhostCaptureScreen(db: widget.db, point: widget.point)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.point;
    final anchor = _frames.isEmpty ? null : _frames.first;
    final current = _frames.isEmpty ? null : _frames[_index];
    return Scaffold(
      appBar: AppBar(title: Text(p.name)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Metrics.gutter),
              children: [
                MonoLabel(
                  [
                    if (p.subject != null) p.subject!,
                    '${p.bearingDeg.toStringAsFixed(0)}°',
                    '${_frames.length} visit${_frames.length == 1 ? '' : 's'}',
                    if (p.nextDueOn != null) 'next ${p.nextDueOn}',
                  ].join(' · '),
                  size: 9.5,
                  spacing: 1.4,
                  opacity: 0.75,
                ),
                const SizedBox(height: 12),
                if (_frames.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Text(
                      'No frames yet. The first visit anchors the point — '
                      'stand at the spot, aim at the subject, shoot.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontFamily: Type.serif, fontSize: 15.5),
                    ),
                  )
                else ...[
                  // Anchor beside the scrubbed frame.
                  Row(
                    children: [
                      Expanded(
                        child: _framed(anchor!,
                            label: 'ANCHOR · ${_date(anchor.visit.visitedAt)}')),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _framed(current!,
                            label: _index == 0
                                ? 'SAME FRAME'
                                : _date(current.visit.visitedAt))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_frames.length > 1)
                    Slider(
                      value: _index.toDouble(),
                      min: 0,
                      max: (_frames.length - 1).toDouble(),
                      divisions: _frames.length - 1,
                      activeColor: Press.oxblood,
                      label: _date(current.visit.visitedAt),
                      onChanged: (v) => setState(() => _index = v.round()),
                    ),
                  // Big view of the scrubbed frame.
                  AspectRatio(
                    aspectRatio: 4 / 3,
                    child: Container(
                      decoration: BoxDecoration(
                          border: Border.all(color: Press.borderInk, width: 1.5)),
                      child: Image.file(File(current.media.localPath!),
                          fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(height: 6),
                  MonoLabel(
                    [
                      _date(current.visit.visitedAt),
                      if (current.visit.actualBearingDeg != null)
                        '${current.visit.actualBearingDeg!.toStringAsFixed(0)}°',
                      if (current.visit.notes != null) current.visit.notes!,
                    ].join(' · '),
                    size: 9.5,
                    opacity: 0.75,
                  ),
                  const SizedBox(height: 12),
                  // Strip of all frames.
                  SizedBox(
                    height: 64,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _frames.length,
                      itemBuilder: (context, i) => GestureDetector(
                        onTap: () => setState(() => _index = i),
                        child: Container(
                          width: 84,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: i == _index
                                    ? Press.oxblood
                                    : Press.ink,
                                width: i == _index ? 2.5 : 1),
                            image: DecorationImage(
                                image: FileImage(File(
                                    _frames[i].media.thumbPath ??
                                        _frames[i].media.localPath!)),
                                fit: BoxFit.cover),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  height: 58,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: Text(_frames.isEmpty
                        ? 'TAKE THE FIRST FRAME'
                        : 'CAPTURE A VISIT'),
                    onPressed: _capture,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _framed(_Frame f, {required String label}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            decoration:
                BoxDecoration(border: Border.all(color: Press.borderInk, width: 1)),
            child: Image.file(
                File(f.media.thumbPath ?? f.media.localPath!),
                fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 4),
        MonoLabel(label, size: 8.5, spacing: 1.2, opacity: 0.75),
      ],
    );
  }
}
