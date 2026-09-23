import 'package:drift/drift.dart' hide Column;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../db/seed.dart' show parseCsv;
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Species list import (spec §6 "CSV for the species library, with column
/// mapping"; D-015 keeps this as the *optional* path — most people should
/// never need to upload a list). Pick a CSV, say which column is which,
/// review, import as this place's own starred taxa.
class SpeciesImportScreen extends StatefulWidget {
  const SpeciesImportScreen({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<SpeciesImportScreen> createState() => _SpeciesImportScreenState();
}

const _fields = {
  'scientific': 'Scientific name (required)',
  'common': 'Common name',
  'family': 'Family',
  'growth': 'Growth form',
  'nativity': 'Nativity',
  'usda': 'USDA symbol',
  'notes': 'Notes',
};

const _growthForms = {
  'tree',
  'shrub',
  'forb',
  'graminoid',
  'vine',
  'succulent',
  'fern',
  'moss',
  'other',
};
const _nativities = {
  'native',
  'introduced',
  'invasive',
  'cultivated',
  'unknown',
};

class _SpeciesImportScreenState extends State<SpeciesImportScreen> {
  List<String> _headers = [];
  List<List<String>> _rows = [];
  final Map<String, int?> _map = {for (final k in _fields.keys) k: null};
  bool _importing = false;
  String? _status;
  String? _fileName;

  Future<void> _pick() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: 'CSV', extensions: ['csv', 'txt']),
      ],
    );
    if (file == null) return;
    try {
      final rows = parseCsv(await file.readAsString());
      if (rows.isEmpty) {
        setState(() => _status = 'That file is empty.');
        return;
      }
      final headers = rows.first.map((h) => h.trim()).toList();
      setState(() {
        _fileName = file.name;
        _headers = headers;
        _rows = rows
            .skip(1)
            .where((r) => r.any((c) => c.trim().isNotEmpty))
            .toList();
        _status = null;
        // Guess the mapping from header names.
        for (final k in _map.keys) {
          _map[k] = null;
        }
        for (var i = 0; i < headers.length; i++) {
          final h = headers[i].toLowerCase();
          if (_map['scientific'] == null &&
              (h.contains('scientific') ||
                  h.contains('latin') ||
                  h == 'species')) {
            _map['scientific'] = i;
          } else if (_map['common'] == null && h.contains('common')) {
            _map['common'] = i;
          } else if (_map['family'] == null && h.contains('family')) {
            _map['family'] = i;
          } else if (_map['growth'] == null &&
              (h.contains('growth') ||
                  h.contains('habit') ||
                  h.contains('form'))) {
            _map['growth'] = i;
          } else if (_map['nativity'] == null &&
              (h.contains('nativ') ||
                  h.contains('origin') ||
                  h.contains('status'))) {
            _map['nativity'] = i;
          } else if (_map['usda'] == null &&
              (h.contains('usda') || h.contains('symbol'))) {
            _map['usda'] = i;
          } else if (_map['notes'] == null && h.contains('note')) {
            _map['notes'] = i;
          }
        }
      });
    } catch (e) {
      setState(() => _status = 'Could not read ${file.name}: $e');
    }
  }

  String? _cell(List<String> row, String key) {
    final i = _map[key];
    if (i == null || i >= row.length) return null;
    final v = row[i].trim();
    return v.isEmpty ? null : v;
  }

  String? _growth(String? raw) {
    if (raw == null) return null;
    final v = raw.toLowerCase().trim();
    if (_growthForms.contains(v)) return v;
    if (v.startsWith('grass') || v.contains('sedge') || v.contains('rush')) {
      return 'graminoid';
    }
    if (v.contains('herb') || v.contains('wildflower')) return 'forb';
    if (v.contains('tree')) return 'tree';
    if (v.contains('shrub') || v.contains('bush')) return 'shrub';
    if (v.contains('vine')) return 'vine';
    if (v.contains('cact') || v.contains('succulent')) return 'succulent';
    return 'other';
  }

  String? _nativity(String? raw) {
    if (raw == null) return null;
    final v = raw.toLowerCase().trim();
    if (_nativities.contains(v)) return v;
    if (v.startsWith('n') || v.contains('native')) return 'native';
    if (v.contains('invas') || v.contains('noxious')) return 'invasive';
    if (v.contains('introd') || v.contains('exotic') || v.contains('non')) {
      return 'introduced';
    }
    if (v.contains('cultiv') || v.contains('planted')) return 'cultivated';
    return 'unknown';
  }

  Future<void> _import() async {
    if (_importing || _map['scientific'] == null) return;
    setState(() {
      _importing = true;
      _status = 'Importing…';
    });
    final db = widget.db;
    var added = 0;
    var updated = 0;
    var skipped = 0;
    try {
      await db.transaction(() async {
        for (final row in _rows) {
          final sci = _cell(row, 'scientific');
          if (sci == null) {
            skipped++;
            continue;
          }
          final now = nowUtcIso();
          // Match on scientific name (global seed or this place) so an
          // imported list stars what's already there instead of duplicating.
          final existing =
              await (db.select(db.taxa)
                    ..where(
                      (t) => t.scientificName.lower().equals(sci.toLowerCase()),
                    )
                    ..where((t) => t.deletedAt.isNull())
                    ..limit(1))
                  .getSingleOrNull();
          final common = _cell(row, 'common');
          if (existing != null) {
            // Star it; only fill a common name where the library has none,
            // and never rename a shared (global) taxon from one place's list.
            final fillName =
                common != null &&
                existing.commonName == null &&
                existing.propertyId == widget.property.id;
            await (db.update(
              db.taxa,
            )..where((t) => t.id.equals(existing.id))).write(
              TaxaCompanion(
                isFavorite: Value(1),
                commonName: fillName ? Value(common) : Value.absent(),
                updatedAt: Value(now),
              ),
            );
            updated++;
            continue;
          }
          await db
              .into(db.taxa)
              .insert(
                TaxaCompanion.insert(
                  id: newId(),
                  propertyId: Value(widget.property.id),
                  scientificName: sci,
                  commonName: Value(common),
                  family: Value(_cell(row, 'family')),
                  growthForm: Value(_growth(_cell(row, 'growth'))),
                  nativity: Value(_nativity(_cell(row, 'nativity'))),
                  usdaPlantsSymbol: Value(_cell(row, 'usda')),
                  notes: Value(_cell(row, 'notes')),
                  isFavorite: Value(1),
                  createdBy: Value('import'),
                  createdAt: now,
                  updatedAt: now,
                ),
              );
          added++;
        }
      });
      setState(() {
        _status =
            'Added $added, starred $updated already in the library'
            '${skipped > 0 ? ', skipped $skipped without a name' : ''}.';
        _rows = [];
        _headers = [];
      });
    } catch (e) {
      setState(() => _status = 'Nothing was imported — $e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _map['scientific'] != null && _rows.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text('Import species list')),
      body: ListView(
        padding: EdgeInsets.all(Metrics.gutter),
        children: [
          Text(
            'Optional. The library already has the regional list; this adds '
            'your own — from a nursery order, a survey, a spreadsheet. Pick '
            'the CSV, then tell it which column is which.',
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 15.5,
              height: 1.45,
            ),
          ),
          SizedBox(height: 14),
          SizedBox(
            height: 58,
            child: OutlinedButton.icon(
              icon: Icon(Icons.table_chart_outlined),
              label: Text(_fileName == null ? 'CHOOSE A CSV' : _fileName!),
              onPressed: _importing ? null : _pick,
            ),
          ),
          if (_headers.isNotEmpty) ...[
            SizedBox(height: 18),
            MonoLabel(
              '${_rows.length} rows · which column is which?',
              size: 9,
              spacing: 1.6,
              opacity: 0.75,
            ),
            SizedBox(height: 6),
            for (final e in _fields.entries)
              Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: DropdownButtonFormField<int?>(
                  initialValue: _map[e.key],
                  decoration: InputDecoration(labelText: e.value),
                  items: [
                    DropdownMenuItem<int?>(
                      value: null,
                      child: Text('— not in this file —'),
                    ),
                    for (var i = 0; i < _headers.length; i++)
                      DropdownMenuItem<int?>(
                        value: i,
                        child: Text(
                          _headers[i].isEmpty ? 'Column ${i + 1}' : _headers[i],
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _map[e.key] = v),
                ),
              ),
            if (_map['scientific'] != null && _rows.isNotEmpty) ...[
              SizedBox(height: 6),
              MonoLabel('Preview', size: 9, spacing: 1.8),
              const SizedBox(height: 4),
              for (final row in _rows.take(5))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    [
                      _cell(row, 'scientific') ?? '(no name — skipped)',
                      if (_cell(row, 'common') != null) _cell(row, 'common')!,
                      if (_growth(_cell(row, 'growth')) != null)
                        _growth(_cell(row, 'growth'))!,
                      if (_nativity(_cell(row, 'nativity')) != null)
                        _nativity(_cell(row, 'nativity'))!,
                    ].join(' · '),
                    style: TextStyle(fontFamily: Type.serif, fontSize: 14),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 58,
              child: FilledButton(
                onPressed: ready && !_importing ? _import : null,
                child: Text(
                  _importing ? 'IMPORTING…' : 'IMPORT ${_rows.length} SPECIES',
                ),
              ),
            ),
          ],
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                _status!,
                style: TextStyle(fontFamily: Type.serif, fontSize: 15),
              ),
            ),
        ],
      ),
    );
  }
}
