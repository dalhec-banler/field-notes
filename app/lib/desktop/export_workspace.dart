import 'dart:async';
import 'dart:convert';
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
import '../export/removal_plan.dart';
import '../export/plate_subject_loader.dart';
import '../map/imagery_sources.dart';
import '../map/record_ink.dart';
import '../map/tile_cache.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

part 'export_workspace/core.dart';
part 'export_workspace/render.dart';
part 'export_workspace/controls.dart';
part 'export_workspace/page.dart';

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
  const ExportWorkspace({super.key, required this.db, required this.property});
  final FieldNotesDb db;
  final Property property;

  @override
  State<ExportWorkspace> createState() => _ExportWorkspaceState();
}

/// Split along its concerns (D-038 item 7): state in `export_workspace/
/// core.dart`, drawing and saving in `render.dart`, the small controls in
/// `controls.dart`, the composed page in `page.dart`. The bench's layout
/// stays here.
class _ExportWorkspaceState extends State<ExportWorkspace>
    with _ExportCore, _ExportRender, _ExportControls {
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
        .changes({
          widget.db.observations,
          widget.db.zones,
          widget.db.features,
          widget.db.tracks,
          widget.db.properties,
        })
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
      _speciesSel.clear();
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
                MonoLabel('Document', size: 9, spacing: 1.8),
                SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (id, label) in _docs)
                      _choiceChip(label, _doc == id, () {
                        setState(() => _doc = id);
                        _scheduleRender();
                      }),
                  ],
                ),
                SizedBox(height: 6),
                MonoLabel('Base', size: 9, spacing: 1.8),
                SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (id, label) in _bases)
                      _choiceChip(label, _base == id, () {
                        setState(() => _base = id);
                        _scheduleRender();
                      }),
                  ],
                ),
                SizedBox(height: 6),
                MonoLabel('Sheet', size: 9, spacing: 1.8),
                SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final pg in PlatePage.values)
                      _choiceChip(pg.label, _page == pg, () {
                        setState(() => _page = pg);
                        _scheduleRender();
                      }),
                  ],
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
                  'Hydrology · USGS',
                  _layers.hydro,
                  (v) => _layers = _layers.copyWith(hydro: v),
                ),
                _layerRow(
                  'Elevation contours · USGS',
                  _layers.contours,
                  (v) => _layers = _layers.copyWith(contours: v),
                ),
                _layerRow(
                  'Soil map units · USDA',
                  _layers.soils,
                  (v) => _layers = _layers.copyWith(soils: v),
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
                if (_layers.records && _recordGroups.isNotEmpty) ...[
                  Padding(
                    padding: EdgeInsets.only(top: 2, bottom: 4),
                    child: MonoLabel(
                      'Pick what goes on the plate — each pick wears its '
                      'own colour. None picked = every record, type '
                      'colours.',
                      size: 8.5,
                      opacity: 0.65,
                    ),
                  ),
                  for (final realm in RecordRealm.values) ...[
                    if (_recordGroups.any((g) => _realmOf(g) == realm)) ...[
                      Padding(
                        padding: EdgeInsets.only(top: 6, bottom: 2),
                        child: MonoLabel(
                          realmTitles[realm]!,
                          size: 8.5,
                          spacing: 1.8,
                          color: Press.oxblood,
                        ),
                      ),
                      for (final g in _recordGroups)
                        if (_realmOf(g) == realm) _speciesRowUi(g),
                    ],
                  ],
                ],
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
                      hintText: 'NRCS · your state wildlife agency · a neighbour',
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
                      ('pdf', 'PDF — the sheet as it prints'),
                      ('png', 'PNG — the page as an image'),
                      // The plan is a printed hand-over; the editable and
                      // interactive twins are the map plate's.
                      if (!_removalPlan) ...[
                        ('docx', 'Word — editable, letter size'),
                        ('html', 'HTML — interactive map'),
                      ],
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
}
