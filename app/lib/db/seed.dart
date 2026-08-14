import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'database.dart';

const _seedAsset = 'assets/seed/taxa_seed.csv';

/// Loads the bundled regional species library into `taxa` on first run.
/// Seed rows are global (property_id NULL, spec §4.4). No-op if any global
/// taxa already exist, so user edits are never clobbered.
Future<int> seedTaxaIfEmpty(FieldNotesDb db, {String? csvText}) async {
  final existing = await (db.select(db.taxa)
        ..where((t) => t.propertyId.isNull())
        ..limit(1))
      .get();
  if (existing.isNotEmpty) return 0;

  csvText ??= await rootBundle.loadString(_seedAsset);
  final rows = _parseCsv(csvText);
  if (rows.isEmpty) return 0;

  final header = rows.first;
  final col = {for (var i = 0; i < header.length; i++) header[i]: i};
  String? field(List<String> row, String name) {
    final i = col[name];
    if (i == null || i >= row.length) return null;
    final v = row[i].trim();
    return v.isEmpty ? null : v;
  }

  final now = nowUtcIso();
  var inserted = 0;
  await db.batch((batch) {
    for (final row in rows.skip(1)) {
      final scientific = field(row, 'scientific_name');
      if (scientific == null) continue;
      batch.insert(
        db.taxa,
        TaxaCompanion.insert(
          id: newId(),
          scientificName: scientific,
          commonName: Value(field(row, 'common_name')),
          family: Value(field(row, 'family')),
          growthForm: Value(field(row, 'growth_form')),
          nativity: Value(field(row, 'nativity')),
          usdaPlantsSymbol: Value(field(row, 'usda_plants_symbol')),
          isFavorite: Value(field(row, 'is_favorite') == '1' ? 1 : 0),
          notes: Value(field(row, 'notes')),
          createdAt: now,
          updatedAt: now,
        ),
      );
      inserted++;
    }
  });
  return inserted;
}

/// Minimal RFC-4180 CSV parser (quoted fields, escaped quotes, CRLF).
List<List<String>> _parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.length > 1 || row.first.isNotEmpty) rows.add(row);
      row = <String>[];
    } else {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    if (row.length > 1 || row.first.isNotEmpty) rows.add(row);
  }
  return rows;
}
