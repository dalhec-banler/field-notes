import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide Column;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../db/database.dart';
import '../export/map_docx.dart';
import '../export/map_document.dart';
import '../export/map_html.dart';
import '../export/map_plate.dart';
import '../export/map_report.dart';
import '../export/plate_subject_loader.dart';
import '../map/imagery_sources.dart';
import '../map/tile_cache.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// The desk's publishing bench, redesigned to Austin's spec (2026-09-03):
/// "it's basically just the map from the phone screen, with whatever you
/// wanted tagged on it, then below it a legend and tables that identify
/// the things that are on the map."
///
/// So: layers on the left, and on the right the composed LETTER PAGE —
/// map on top, legend and tables below, exactly what the PDF says —
/// re-rendered automatically when anything changes. No DRAW button, no
/// blind saves: every format renders the page you are looking at, and
/// PNG saves the page, not a bare map.
class ExportWorkspace extends StatefulWidget {
  ExportWorkspace({super.key, required this.db, required this.property});
  final FieldNotesDb db;
  final Property property;

  @override
  State<ExportWorkspace> createState() => _ExportWorkspaceState();
}

class _ExportWorkspaceState extends State<ExportWorkspace> {
  PlateLayers _layers = const PlateLayers();
  final _title = TextEditingController();
  final _preparedFor = TextEditingController();
  final _notes = TextEditingController();
  PlateSubject? _subject;
  PlateResult? _plate;
  bool _rendering = false;
  bool _saving = false;
  bool _detailsOpen = false;
  String? _note; // warnings and save confirmations only
  int _seq = 0;
  Timer? _debounce;
  StreamSubscription<void>? _watch;

  /// Session tile cache: layer toggles never change the imagery, so only
  /// the first render waits on the network.
  final _tiles = TileCache();
  late final TileFetcher _fetch = () {
    final primary = httpTileFetcher(template: activeImagery.template);
    final chained = activeImagery.id == 'usgs'
        ? primary
        : tileFetcherWithFallback(primary, httpTileFetcher());
    return _tiles.wrap(chained);
  }();

  final _pageKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _title.text = widget.property.name;
    for (final c in [_title, _preparedFor, _notes]) {
      c.addListener(() => setState(() {}));
    }
    _scheduleRender(immediate: true);
    // A desk edit a minute ago belongs on the plate without a button.
    _watch = widget.db
        .customSelect(
          'SELECT 1',
          readsFrom: {
            widget.db.observations,
            widget.db.zones,
            widget.db.features,
            widget.db.tracks,
            widget.db.properties,
          },
        )
        .watch()
        .listen((_) => _scheduleRender());
  }

  @override
  void didUpdateWidget(covariant ExportWorkspace old) {
    super.didUpdateWidget(old);
    if (old.property.id != widget.property.id) {
      // New place, clean sheet — a stale "Prepared for" is how the wrong
      // partner's name ships (audit finding 10).
      _title.text = widget.property.name;
      _preparedFor.clear();
      _notes.clear();
      _plate = null;
      _scheduleRender(immediate: true);
    }
  }

  @override
  void dispose() {
    _watch?.cancel();
    _debounce?.cancel();
    _title.dispose();
    _preparedFor.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _scheduleRender({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(
      Duration(milliseconds: immediate ? 0 : 450),
      _render,
    );
  }

  Future<void> _render() async {
    if (!mounted) return;
    final seq = ++_seq;
    setState(() => _rendering = true);
    try {
      final fresh = await loadPlateSubject(widget.db, widget.property);
      final r = await MapPlate(
        fetchTile: _fetch,
        maxZoom: activeImagery.maxZoom,
      ).render(
        fresh,
        layers: _layers,
        attribution: 'Imagery: ${activeImagery.attribution} · Field Notes',
      );
      if (!mounted || seq != _seq) return; // a newer render superseded this
      setState(() {
        _subject = fresh;
        _plate = r;
        _note = r.tilesMissing > 0
            ? '${r.tilesMissing} imagery tiles unavailable'
            : null;
      });
    } catch (e) {
      if (mounted && seq == _seq) {
        setState(() => _note = 'Could not draw the plate: $e');
      }
    } finally {
      if (mounted && seq == _seq) setState(() => _rendering = false);
    }
  }

  MapDocument? get _document {
    final p = _plate;
    final s = _subject;
    if (p == null || s == null) return null;
    return MapDocument(
      title: _title.text.trim().isEmpty
          ? widget.property.name
          : _title.text.trim(),
      plate: p,
      subject: s,
      layers: _layers,
      preparedFor: _preparedFor.text,
      notes: _notes.text,
    );
  }

  String get _baseName {
    final t = (_title.text.trim().isEmpty ? widget.property.name : _title.text)
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final d = DateTime.now();
    return '$t-map-${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _save(String ext, Future<Uint8List> Function() bytes) async {
    if (_saving) return;
    final loc = await getSaveLocation(
      suggestedName: '$_baseName.$ext',
      acceptedTypeGroups: [
        XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
      ],
    );
    if (loc == null) return;
    setState(() => _saving = true);
    try {
      final data = await bytes();
      await File(loc.path).writeAsBytes(data, flush: true);
      if (mounted) setState(() => _note = 'Saved ${loc.path}');
    } catch (e) {
      if (mounted) setState(() => _note = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The page as pixels — what PNG means now: the composed document, not
  /// a bare map with nothing under it (audit finding 5).
  Future<Uint8List> _pagePng() async {
    final boundary =
        _pageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await boundary.toImage(pixelRatio: 2.5);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  Future<void> _saveAs(String ext) async {
    final d = _document;
    if (d == null) return;
    switch (ext) {
      case 'pdf':
        await _save('pdf', () async {
          final theme = await MapReport.loadTheme();
          return MapReport.build(d, theme: theme);
        });
      case 'png':
        await _save('png', _pagePng);
      case 'docx':
        await _save('docx', () async => MapDocx.build(d));
      case 'html':
        await _save('html', () async {
          final html = MapHtml.build(
            d.subject,
            layers: d.layers,
            title: d.title,
            dateLine: d.dateLine,
          );
          return Uint8List.fromList(html.codeUnits);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _document;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 300,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(color: Press.borderInk, width: 1.5),
              ),
            ),
            child: ListView(
              padding: EdgeInsets.fromLTRB(14, 12, 14, 14),
              children: [
                Kicker('Map plate'),
                SizedBox(height: 4),
                Text(
                  'WHAT GOES ON IT',
                  style: TextStyle(
                    fontFamily: Type.slab,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                    height: 0.9,
                  ),
                ),
                SizedBox(height: 12),
                _layerRow(
                  'Property boundary',
                  _layers.boundary,
                  (v) => _layers = _layers.copyWith(boundary: v),
                  count: _subject?.boundaryGeojson == null ? 0 : 1,
                ),
                _layerRow(
                  'Zones',
                  _layers.zones,
                  (v) => _layers = _layers.copyWith(zones: v),
                  count: _subject?.zones.length,
                ),
                _layerRow(
                  'Zone names',
                  _layers.zoneLabels,
                  (v) => _layers = _layers.copyWith(zoneLabels: v),
                ),
                _layerRow(
                  'Features',
                  _layers.features,
                  (v) => _layers = _layers.copyWith(features: v),
                  count: _subject?.features.length,
                ),
                _layerRow(
                  'Walked tracks',
                  _layers.tracks,
                  (v) => _layers = _layers.copyWith(tracks: v),
                  count: _subject?.tracks.length,
                ),
                _layerRow(
                  'Field records',
                  _layers.records,
                  (v) => _layers = _layers.copyWith(records: v),
                  count: _subject?.records.length,
                ),
                if (_layers.records)
                  Padding(
                    padding: EdgeInsets.only(left: 2, bottom: 8),
                    child: Text(
                      'Records put the exact spot of every observation on '
                      'the file. Fine for a partner you trust; not for the '
                      'website.',
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 12.5,
                        height: 1.4,
                        color: Press.oxblood,
                      ),
                    ),
                  ),
                SizedBox(height: 12),
                InkWell(
                  onTap: () => setState(() => _detailsOpen = !_detailsOpen),
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Icon(
                          _detailsOpen
                              ? Icons.arrow_drop_down
                              : Icons.arrow_right,
                          size: 20,
                          color: Press.inkSoft,
                        ),
                        MonoLabel('DOCUMENT DETAILS', size: 9, spacing: 1.8),
                      ],
                    ),
                  ),
                ),
                if (_detailsOpen) ...[
                  SizedBox(height: 4),
                  MonoLabel('Title', size: 9, spacing: 1.8),
                  SizedBox(height: 6),
                  TextField(
                    controller: _title,
                    decoration: InputDecoration(border: OutlineInputBorder()),
                    style: TextStyle(fontFamily: Type.serif, fontSize: 15),
                  ),
                  SizedBox(height: 10),
                  MonoLabel('Prepared for (optional)', size: 9, spacing: 1.8),
                  SizedBox(height: 6),
                  TextField(
                    controller: _preparedFor,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'TPWD · NRCS · a neighbour',
                    ),
                    style: TextStyle(fontFamily: Type.serif, fontSize: 15),
                  ),
                  SizedBox(height: 10),
                  MonoLabel('Notes for the document', size: 9, spacing: 1.8),
                  SizedBox(height: 6),
                  TextField(
                    controller: _notes,
                    minLines: 3,
                    maxLines: 8,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'What this map shows, for whoever reads it.',
                    ),
                    style: TextStyle(fontFamily: Type.serif, fontSize: 14.5),
                  ),
                ],
                SizedBox(height: 14),
                PopupMenuButton<String>(
                  enabled: d != null && !_saving,
                  tooltip: 'Save the page as a file',
                  color: Press.paper,
                  onSelected: _saveAs,
                  itemBuilder: (_) => [
                    for (final (ext, label) in [
                      ('pdf', 'PDF — the page as it prints'),
                      ('png', 'PNG — the page as an image'),
                      ('docx', 'Word — editable document'),
                      ('html', 'HTML — interactive map'),
                    ])
                      PopupMenuItem(
                        value: ext,
                        child: Text(
                          label,
                          style: TextStyle(
                            fontFamily: Type.serif,
                            fontSize: 14.5,
                          ),
                        ),
                      ),
                  ],
                  child: Container(
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: d == null || _saving
                          ? Press.inkSoft.withValues(alpha: 0.4)
                          : Press.ink,
                    ),
                    child: MonoLabel(
                      _saving ? 'SAVING…' : 'SAVE ▾',
                      size: 10,
                      spacing: 1.8,
                      color: Press.paperRaised,
                    ),
                  ),
                ),
                SizedBox(height: 8),
                MonoLabel(
                  'Imagery: ${activeImagery.label}. Fetched for the framed '
                  'area only; nothing else leaves this computer until you '
                  'save a file.',
                  size: 8.5,
                  opacity: 0.6,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: Container(
                  color: Press.paperEdge,
                  child: _plate == null
                      ? Center(
                          child: MonoLabel(
                            _rendering
                                ? '— drawing the page —'
                                : 'Loading the property…',
                            size: 10,
                            spacing: 2,
                            opacity: 0.5,
                          ),
                        )
                      : Stack(
                          children: [
                            Positioned.fill(
                              child: SingleChildScrollView(
                                padding: EdgeInsets.all(24),
                                child: Center(
                                  child: d == null
                                      ? SizedBox.shrink()
                                      : RepaintBoundary(
                                          key: _pageKey,
                                          child: _Page(document: d),
                                        ),
                                ),
                              ),
                            ),
                            if (_rendering)
                              Positioned(
                                top: 10,
                                right: 12,
                                child: Container(
                                  color: Press.ink,
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  child: MonoLabel(
                                    'REDRAWING…',
                                    size: 8.5,
                                    spacing: 1.6,
                                    color: Press.paperRaised,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
              if (_note != null)
                Container(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Press.borderInk, width: 1.5),
                    ),
                  ),
                  padding: EdgeInsets.fromLTRB(14, 8, 14, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: MonoLabel(
                          _note!,
                          size: 9,
                          opacity: 0.8,
                          maxLines: 2,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _layerRow(
    String label,
    bool on,
    void Function(bool) set, {
    int? count,
  }) {
    return InkWell(
      onTap: () {
        setState(() => set(!on));
        _scheduleRender();
      },
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: on ? Press.ink : null,
                border: Border.all(color: Press.borderInk, width: 1.5),
              ),
              child: on
                  ? Icon(Icons.check, size: 14, color: Press.paper)
                  : null,
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontFamily: Type.serif, fontSize: 15),
              ),
            ),
            if (count != null) MonoLabel('$count', size: 9, opacity: 0.6),
          ],
        ),
      ),
    );
  }
}

/// The letter page, composed live: what you see is what every format says.
/// Fixed print palette on paper white — the page looks the same from
/// either skin, exactly like the PDF it mirrors (MapReport's layout).
class _Page extends StatelessWidget {
  const _Page({required this.document});
  final MapDocument document;

  static const _paper = Color(0xFFF7F6F2);
  static const _ink = Color(0xFF1B1813);
  static const _soft = Color(0xFF6B655C);
  static const _rule = Color(0xFFB8AE9C);
  static const _oxblood = Color(0xFF8B2E22);

  @override
  Widget build(BuildContext context) {
    final d = document;
    final legend = d.marksLegend;
    final half = (legend.length / 2).ceil();

    Widget kicker(String s) => Row(
      children: [
        Container(width: 15, height: 2, color: _oxblood),
        SizedBox(width: 6),
        Text(
          s.toUpperCase(),
          style: TextStyle(
            fontFamily: Type.mono,
            fontSize: 8.5,
            letterSpacing: 1.6,
            color: _soft,
          ),
        ),
      ],
    );

    Widget legendRow((int, String) e) => Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Container(width: 10, height: 10, color: Color(e.$1)),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              e.$2,
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 10.5,
                color: _ink,
              ),
            ),
          ),
        ],
      ),
    );

    Widget tableRow(List<Widget> cells) => Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _rule, width: 0.5)),
      ),
      padding: EdgeInsets.symmetric(vertical: 3.5),
      child: Row(children: cells),
    );

    Text cell(
      String s, {
      bool right = false,
      Color color = _ink,
    }) => Text(
      s,
      textAlign: right ? TextAlign.right : TextAlign.left,
      style: TextStyle(fontFamily: Type.serif, fontSize: 10.5, color: color),
    );

    return Container(
      width: 700,
      color: _paper,
      padding: EdgeInsets.all(55),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          kicker('Field Notes · map'),
          SizedBox(height: 5),
          Text(
            d.title.toUpperCase(),
            style: TextStyle(
              fontFamily: Type.slab,
              fontWeight: FontWeight.w900,
              fontSize: 23,
              height: 1,
              color: _ink,
            ),
          ),
          SizedBox(height: 3),
          Text(
            d.subtitle,
            style: TextStyle(
              fontFamily: Type.mono,
              fontSize: 10,
              color: _soft,
            ),
          ),
          SizedBox(height: 13),
          Container(
            decoration: BoxDecoration(border: Border.all(color: _ink)),
            child: Image.memory(
              d.plate.png,
              width: 588,
              fit: BoxFit.fitWidth,
              gaplessPlayback: true,
            ),
          ),
          SizedBox(height: 15),
          if (legend.isNotEmpty) ...[
            kicker('Legend'),
            SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [for (final e in legend.take(half)) legendRow(e)],
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [for (final e in legend.skip(half)) legendRow(e)],
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
          ],
          if (d.zoneRowsInk.isNotEmpty) ...[
            kicker('Zones'),
            SizedBox(height: 5),
            for (final (ink, name, acres) in d.zoneRowsInk)
              tableRow([
                Container(width: 10, height: 10, color: Color(ink)),
                SizedBox(width: 8),
                Expanded(child: cell(name)),
                SizedBox(width: 80, child: cell(acres, right: true, color: _soft)),
              ]),
            SizedBox(height: 12),
          ],
          if (d.featureRows.isNotEmpty) ...[
            kicker('Features'),
            SizedBox(height: 5),
            for (final (name, cls) in d.featureRows)
              tableRow([
                Expanded(child: cell(name)),
                SizedBox(width: 110, child: cell(cls, right: true, color: _soft)),
              ]),
            SizedBox(height: 12),
          ],
          if (d.recordRows.isNotEmpty) ...[
            kicker('Field records on this map'),
            SizedBox(height: 5),
            for (final (label, count) in d.recordRows)
              tableRow([
                Expanded(child: cell(label)),
                SizedBox(width: 60, child: cell(count, right: true, color: _soft)),
              ]),
            SizedBox(height: 12),
          ],
          if ((d.notes ?? '').trim().isNotEmpty) ...[
            kicker('Notes'),
            SizedBox(height: 6),
            Text(
              d.notes!.trim(),
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 11.5,
                height: 1.5,
                color: _ink,
              ),
            ),
            SizedBox(height: 12),
          ],
          SizedBox(height: 8),
          Text(
            d.sourceLine,
            style: TextStyle(
              fontFamily: Type.mono,
              fontSize: 8,
              height: 1.4,
              color: _soft,
            ),
          ),
        ],
      ),
    );
  }
}
