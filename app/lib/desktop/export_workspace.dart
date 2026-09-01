import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../export/map_docx.dart';
import '../export/map_document.dart';
import '../export/map_html.dart';
import '../export/map_plate.dart';
import '../export/map_report.dart';
import '../export/plate_subject_loader.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// The desk's publishing bench (D-024): compose a map plate from the
/// property's layers, see it, and save it as PNG, PDF, or an interactive
/// HTML page. Records are off by default — they carry the coordinates of
/// private land — and switching them on says so next to the switch.
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
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _title.text = widget.property.name;
    _loadSubject();
  }

  @override
  void didUpdateWidget(covariant ExportWorkspace old) {
    super.didUpdateWidget(old);
    if (old.property.id != widget.property.id) {
      _title.text = widget.property.name;
      _plate = null;
      _loadSubject();
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _preparedFor.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadSubject() async {
    final s = await loadPlateSubject(widget.db, widget.property);
    if (mounted) setState(() => _subject = s);
  }

  Future<void> _render() async {
    final subject = _subject;
    if (subject == null || _busy) return;
    setState(() {
      _busy = true;
      _status = 'Fetching imagery and drawing…';
    });
    try {
      // Fresh rows every render: a desk edit a minute ago belongs on the
      // plate.
      final fresh = await loadPlateSubject(widget.db, widget.property);
      final r = await MapPlate(fetchTile: httpTileFetcher())
          .render(fresh, layers: _layers);
      if (!mounted) return;
      setState(() {
        _subject = fresh;
        _plate = r;
        _status =
            'Zoom ${r.zoom} · ${r.width}×${r.height} px'
            '${r.tilesMissing > 0 ? ' · ${r.tilesMissing} imagery tiles unavailable' : ''}';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Could not draw the plate: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    if (_busy) return;
    final loc = await getSaveLocation(
      suggestedName: '$_baseName.$ext',
      acceptedTypeGroups: [
        XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
      ],
    );
    if (loc == null) return;
    setState(() {
      _busy = true;
      _status = 'Writing ${ext.toUpperCase()}…';
    });
    try {
      final data = await bytes();
      await File(loc.path).writeAsBytes(data, flush: true);
      if (mounted) setState(() => _status = 'Saved ${loc.path}');
    } catch (e) {
      if (mounted) setState(() => _status = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _savePng() async {
    final p = _plate;
    if (p == null) return;
    await _save('png', () async => p.png);
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

  Future<void> _savePdf() async {
    final d = _document;
    if (d == null) return;
    await _save('pdf', () async {
      final theme = await MapReport.loadTheme();
      return MapReport.build(d, theme: theme);
    });
  }

  Future<void> _saveDocx() async {
    final d = _document;
    if (d == null) return;
    await _save('docx', () async => MapDocx.build(d));
  }

  Future<void> _saveHtml() async {
    final s = _subject;
    if (s == null) return;
    await _save('html', () async {
      final html = MapHtml.build(
        s,
        layers: _layers,
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
      );
      return Uint8List.fromList(utf8.encode(html));
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _subject;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 330,
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
                  count: s?.boundaryGeojson == null ? 0 : 1,
                ),
                _layerRow(
                  'Zones',
                  _layers.zones,
                  (v) => _layers = _layers.copyWith(zones: v),
                  count: s?.zones.length,
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
                  count: s?.features.length,
                ),
                _layerRow(
                  'Walked tracks',
                  _layers.tracks,
                  (v) => _layers = _layers.copyWith(tracks: v),
                  count: s?.tracks.length,
                ),
                _layerRow(
                  'Field records',
                  _layers.records,
                  (v) => _layers = _layers.copyWith(records: v),
                  count: s?.records.length,
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
                SizedBox(height: 10),
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
                SizedBox(height: 14),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    icon: Icon(Icons.map_outlined, size: 18),
                    label: Text(_busy ? 'WORKING…' : 'DRAW THE PLATE'),
                    onPressed: _busy || s == null ? null : _render,
                  ),
                ),
                SizedBox(height: 8),
                MonoLabel(
                  'Imagery comes from USGS for the framed area only. '
                  'Nothing else leaves this computer until you save a file.',
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
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: _plate == null
                        ? MonoLabel(
                            s == null
                                ? 'Loading the property…'
                                : '— Draw the plate to preview it —',
                            size: 10,
                            spacing: 2,
                            opacity: 0.5,
                          )
                        : Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Press.borderInk,
                                width: 1.5,
                              ),
                            ),
                            child: Image.memory(
                              _plate!.png,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                          ),
                  ),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Press.borderInk, width: 1.5),
                  ),
                ),
                padding: EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: MonoLabel(
                        _status ?? '',
                        size: 9,
                        opacity: 0.75,
                        maxLines: 2,
                      ),
                    ),
                    SizedBox(width: 10),
                    _saveButton('SAVE PNG', _plate == null ? null : _savePng),
                    SizedBox(width: 8),
                    _saveButton('SAVE PDF', _plate == null ? null : _savePdf),
                    SizedBox(width: 8),
                    _saveButton('SAVE WORD', _plate == null ? null : _saveDocx),
                    SizedBox(width: 8),
                    _saveButton('SAVE HTML', s == null ? null : _saveHtml),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _saveButton(String label, VoidCallback? onTap) => SizedBox(
    height: 42,
    child: OutlinedButton(onPressed: _busy ? null : onTap, child: Text(label)),
  );

  Widget _layerRow(
    String label,
    bool on,
    void Function(bool) set, {
    int? count,
  }) {
    return InkWell(
      onTap: () => setState(() => set(!on)),
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
