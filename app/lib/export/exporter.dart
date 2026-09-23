import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:native_exif/native_exif.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../protocols/protocol_export.dart';
import 'survival_report.dart';

/// "Take my data" export (spec §6): one folder, open formats, no vendor
/// dependency. Layout mirrors the spec: database.sqlite + data/*.csv +
/// geo/*.geojson + property.kml + media/.
class Exporter {
  Exporter(this.db);

  final FieldNotesDb db;

  /// Exports [property] into [destRoot]; returns the export directory.
  Future<Directory> exportProperty(
    Property property,
    Directory destRoot,
  ) async {
    final date = nowUtcIso().substring(0, 10);
    final safeName = property.name
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '')
        .toLowerCase();
    final dir = Directory(p.join(destRoot.path, '$safeName-export-$date'))
      ..createSync(recursive: true);
    final dataDir = Directory(p.join(dir.path, 'data'))..createSync();
    final geoDir = Directory(p.join(dir.path, 'geo'))..createSync();
    final mediaDir = Directory(p.join(dir.path, 'media', 'photos'))
      ..createSync(recursive: true);
    final audioDir = Directory(p.join(dir.path, 'media', 'audio'))
      ..createSync(recursive: true);

    await _dumpDatabase(File(p.join(dir.path, 'database.sqlite')), property.id);
    await _writeCsvs(property.id, dataDir);
    await _writeGeojson(property.id, geoDir);
    _writeKml(property, File(p.join(geoDir.path, 'property.kml')));
    await _copyMedia(property.id, mediaDir, audioDir);
    // reports/survival-summary.pdf (spec §6).
    try {
      final reports = Directory(p.join(dir.path, 'reports'))..createSync();
      File(p.join(reports.path, 'survival-summary.pdf'))
          .writeAsBytesSync(await SurvivalReport(db).build(property));
    } catch (_) {
      // The PDF is a convenience; the CSVs carry the same data.
    }
    _writeReadme(property, File(p.join(dir.path, 'README.md')));
    return dir;
  }

  Future<void> _dumpDatabase(File out, String propertyId) async {
    // VACUUM INTO produces a clean, consistent single-file copy (spec §11.7).
    if (out.existsSync()) out.deleteSync();
    final path = out.path.replaceAll("'", "''");
    await db.customStatement("VACUUM INTO '$path'");

    // Then it is CUT DOWN to this place (external audit 2026-09-04,
    // finding 2). The CSVs and GeoJSON were always filtered, but the
    // SQLite file was the whole journal: hand a partner the export of a
    // public collection site and they also received the home property —
    // its coordinates, its notes, its deleted rows, its sync history.
    // The folder is named for one place; it now contains one place.
    final copy = sqlite3.open(out.path);
    try {
      copy.execute('PRAGMA foreign_keys = OFF');
      final tables = [
        for (final r in copy.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%'",
        ))
          r['name'] as String,
      ];
      for (final name in tables) {
        // Sync bookkeeping is this device's own business, never a
        // recipient's.
        if (name.startsWith('sync_')) {
          copy.execute('DELETE FROM "$name"');
          continue;
        }
        if (name == 'properties') {
          copy.execute('DELETE FROM properties WHERE id != ?', [propertyId]);
          continue;
        }
        final cols = [
          for (final r in copy.select('PRAGMA table_info("$name")'))
            r['name'] as String,
        ];
        // Reference data (taxa, feature types) has no property and stays.
        if (cols.contains('property_id')) {
          copy.execute('DELETE FROM "$name" WHERE property_id != ?', [
            propertyId,
          ]);
        }
      }
      // Media rows for other places go with them; keep what this place
      // still links to.
      if (tables.contains('media') && tables.contains('media_links')) {
        copy.execute(
          'DELETE FROM media WHERE id NOT IN '
          '(SELECT media_id FROM media_links)',
        );
      }
      copy.execute('VACUUM');
    } finally {
      copy.dispose();
    }
  }

  Future<void> _writeCsvs(String propertyId, Directory dataDir) async {
    Future<void> table(String name, {String? where}) async {
      final clause = where ?? "property_id = '$propertyId'";
      final rows = await db
          .customSelect(
            'SELECT * FROM $name WHERE $clause AND deleted_at IS NULL'
                .replaceFirst(
                  ' AND deleted_at IS NULL',
                  _hasDeletedAt(name) ? ' AND deleted_at IS NULL' : '',
                ),
          )
          .get();
      final file = File(p.join(dataDir.path, '$name.csv'));
      if (rows.isEmpty) {
        file.writeAsStringSync('');
        return;
      }
      final headers = rows.first.data.keys.toList();
      final buf = StringBuffer()..writeln(headers.map(_csvCell).join(','));
      for (final row in rows) {
        buf.writeln(headers.map((h) => _csvCell(row.data[h])).join(','));
      }
      file.writeAsStringSync(buf.toString());
    }

    await table('observations');
    await table('plants');
    await table('plant_checkins');
    await table('planting_events');
    await table('propagation_batches');
    await table('features');
    await table('zones');
    await table(
      'taxa',
      where: "(property_id = '$propertyId' OR property_id IS NULL)",
    );
    await table('detections');
    await table('practices');
    // D-033: monitoring. The raw tables, then the tidy long form a grad
    // student or an ArcGIS user actually wants (ProtocolExport).
    await table('protocols');
    await table('protocol_sites');
    await table('protocol_runs');
    await ProtocolExport(db).writeInto(propertyId, dataDir);
  }

  bool _hasDeletedAt(String tableName) => tableName != 'track_points';

  String _csvCell(Object? v) {
    if (v == null) return '';
    final s = v.toString();
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  Future<void> _writeGeojson(String propertyId, Directory geoDir) async {
    Future<void> collection(
      String fileName,
      String sql,
      Map<String, dynamic> Function(QueryRow) toFeature,
    ) async {
      final rows = await db.customSelect(sql).get();
      final fc = {
        'type': 'FeatureCollection',
        'features': rows.map(toFeature).toList(),
      };
      File(p.join(geoDir.path, fileName))
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(fc));
    }

    await collection(
      'protocol_sites.geojson',
      "SELECT s.*, p.name AS protocol_name, p.method_key, z.name AS zone_name "
          "FROM protocol_sites s "
          "JOIN protocols p ON p.id = s.protocol_id "
          "LEFT JOIN zones z ON z.id = s.zone_id "
          "WHERE s.property_id = '$propertyId' AND s.deleted_at IS NULL",
      (row) => {
        'type': 'Feature',
        'geometry': row.data['geojson'] == null
            ? {
                'type': 'Point',
                'coordinates': [row.data['lng'], row.data['lat']],
              }
            : jsonDecode(row.data['geojson'] as String),
        'properties': {
          'id': row.data['id'],
          'name': row.data['name'],
          'protocol': row.data['protocol_name'],
          'method_key': row.data['method_key'],
          'zone': row.data['zone_name'],
          'bearing_deg': row.data['bearing_deg'],
          'length_m': row.data['length_m'],
          'radius_m': row.data['radius_m'],
          'next_due_on': row.data['next_due_on'],
          'retired_on': row.data['retired_on'],
        },
      },
    );

    await collection(
      'observations.geojson',
      "SELECT o.*, t.scientific_name, t.common_name FROM observations o "
          "LEFT JOIN taxa t ON t.id = o.taxon_id "
          "WHERE o.property_id = '$propertyId' AND o.deleted_at IS NULL",
      (row) => {
        'type': 'Feature',
        // gps_accuracy_m = -1 means "not located": the stored lat/lng is a
        // stand-in (centroid). A null geometry is honest; a point is not.
        'geometry': row.data['gps_accuracy_m'] == -1
            ? null
            : {
                'type': 'Point',
                'coordinates': [row.data['lng'], row.data['lat']],
              },
        'properties': {
          'id': row.data['id'],
          'observed_at': row.data['observed_at'],
          'type': row.data['observation_type'],
          'scientific_name': row.data['scientific_name'],
          'common_name': row.data['common_name'],
          'notes': row.data['notes'],
          'gps_accuracy_m': row.data['gps_accuracy_m'],
          'located': row.data['gps_accuracy_m'] != -1,
        },
      },
    );

    await collection(
      'zones.geojson',
      "SELECT * FROM zones WHERE property_id = '$propertyId' AND deleted_at IS NULL",
      (row) => {
        'type': 'Feature',
        'geometry': jsonDecode(row.data['geojson'] as String),
        'properties': {
          'id': row.data['id'],
          'name': row.data['name'],
          'code': row.data['code'],
          'zone_type': row.data['zone_type'],
          'area_acres': row.data['area_acres'],
        },
      },
    );

    await collection(
      'features.geojson',
      "SELECT f.*, ft.label AS type_label FROM features f "
          "LEFT JOIN feature_types ft ON ft.id = f.feature_type_id "
          "WHERE f.property_id = '$propertyId' AND f.deleted_at IS NULL",
      (row) => {
        'type': 'Feature',
        'geometry': jsonDecode(row.data['geojson'] as String),
        'properties': {
          'id': row.data['id'],
          'name': row.data['name'],
          'feature_type': row.data['type_label'],
          'condition': row.data['current_condition'],
        },
      },
    );

    await collection(
      'plantings.geojson',
      "SELECT pe.*, t.scientific_name, t.common_name FROM planting_events pe "
          "LEFT JOIN taxa t ON t.id = pe.taxon_id "
          "WHERE pe.property_id = '$propertyId' AND pe.deleted_at IS NULL "
          "AND pe.lat IS NOT NULL",
      (row) => {
        'type': 'Feature',
        'geometry': row.data['geojson'] != null
            ? jsonDecode(row.data['geojson'] as String)
            : {
                'type': 'Point',
                'coordinates': [row.data['lng'], row.data['lat']],
              },
        'properties': {
          'id': row.data['id'],
          'planted_on': row.data['planted_on'],
          'scientific_name': row.data['scientific_name'],
          'common_name': row.data['common_name'],
          'count_planted': row.data['count_planted'],
          'stock_source': row.data['stock_source'],
        },
      },
    );

    await collection(
      'tracks.geojson',
      "SELECT * FROM tracks WHERE property_id = '$propertyId' "
          "AND deleted_at IS NULL AND geojson IS NOT NULL",
      (row) => {
        'type': 'Feature',
        'geometry': jsonDecode(row.data['geojson'] as String),
        'properties': {
          'id': row.data['id'],
          'started_at': row.data['started_at'],
          'purpose': row.data['purpose'],
          'distance_m': row.data['distance_m'],
        },
      },
    );
  }

  /// Property boundary as KML — opens in Google Earth (spec §6).
  void _writeKml(Property property, File out) {
    String coordsFromGeojson(String geojson) {
      final geometry = jsonDecode(geojson) as Map<String, dynamic>;
      List<dynamic> ring;
      if (geometry['type'] == 'Polygon') {
        ring = (geometry['coordinates'] as List).first as List;
      } else if (geometry['type'] == 'MultiPolygon') {
        ring = ((geometry['coordinates'] as List).first as List).first as List;
      } else {
        return '';
      }
      return ring.map((c) => '${c[0]},${c[1]},0').join(' ');
    }

    final boundary = property.boundaryGeojson;
    final placemark = boundary == null
        ? (property.centroidLat != null
              ? '''
    <Placemark>
      <name>${_xmlEscape(property.name)}</name>
      <Point><coordinates>${property.centroidLng},${property.centroidLat},0</coordinates></Point>
    </Placemark>'''
              : '')
        : '''
    <Placemark>
      <name>${_xmlEscape(property.name)} boundary</name>
      <Polygon>
        <outerBoundaryIs><LinearRing><coordinates>${coordsFromGeojson(boundary)}</coordinates></LinearRing></outerBoundaryIs>
      </Polygon>
    </Placemark>''';

    out.writeAsStringSync('''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>${_xmlEscape(property.name)}</name>
$placemark
  </Document>
</kml>
''');
  }

  String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  Future<void> _copyMedia(
    String propertyId,
    Directory mediaDir,
    Directory audioDir,
  ) async {
    final rows =
        await (db.select(db.media)
              ..where((m) => m.propertyId.equals(propertyId))
              ..where((m) => m.deletedAt.isNull()))
            .get();
    for (final m in rows) {
      final src = m.localPath;
      if (src == null || !File(src).existsSync()) continue;
      final when = m.capturedAt ?? m.createdAt;
      final ym = when.substring(0, 7).split('-');
      final root = m.mediaType == 'audio' ? audioDir : mediaDir;
      final destDir = Directory(p.join(root.path, ym[0], ym[1]))
        ..createSync(recursive: true);
      final dest = p.join(destDir.path, '${m.id}${p.extension(src)}');
      File(src).copySync(dest);
      if (m.mediaType != 'photo') continue;
      // Spec §6: GPS written into the exported JPEG so the photo carries its
      // location into any other tool. Only the export copy is touched; the
      // original in the media store stays byte-identical (its sha256 is the
      // backup's identity). Skipped where the platform can't (host tests).
      if (m.lat != null && m.lng != null) {
        await _writeExifGps(dest, m.lat!, m.lng!, m.capturedAt ?? m.createdAt);
      }
    }
  }

  static Future<void> _writeExifGps(
    String path,
    double lat,
    double lng,
    String capturedAtIso,
  ) async {
    try {
      final exif = await Exif.fromPath(path);
      try {
        // EXIF DateTimeOriginal is local time with no zone (our own photo
        // import parses it as local, so this round-trips).
        final when = DateTime.tryParse(capturedAtIso)?.toLocal();
        String two(int v) => v.toString().padLeft(2, '0');
        // native_exif takes signed decimal degrees and derives the refs.
        await exif.writeAttributes({
          'GPSLatitude': lat.toString(),
          'GPSLongitude': lng.toString(),
          if (when != null)
            'DateTimeOriginal':
                '${when.year}:${two(when.month)}:${two(when.day)} '
                '${two(when.hour)}:${two(when.minute)}:${two(when.second)}',
        });
      } finally {
        await exif.close();
      }
    } catch (_) {
      // No native EXIF on this platform (or a non-JPEG): the CSV/GeoJSON
      // still carry the coordinates.
    }
  }

  void _writeReadme(Property property, File out) {
    out.writeAsStringSync('''
# ${property.name} — Field Notes export

Everything your field journal knows about this place, in open formats.

- `database.sqlite` — the complete database. Open with any SQLite tool.
- `data/*.csv` — per-table exports for spreadsheets.
- `geo/*.geojson` — observations, zones, features, plantings, tracks,
  monitoring sites. Open in QGIS, or drag onto geojson.io.
- `data/protocol_runs_long.csv` — monitoring answers, one row per site ×
  visit × sample × question (tidy: `filter`, `group_by`, `pivot_wider`).
  Class answers carry both the class and its midpoint; coordinates are
  WGS84 decimal degrees; dates are ISO 8601. `data/protocol_runs_wide.csv`
  has one row per visit with the computed numbers (percent cover, stems
  per acre…). `data/schema.ini` tells ArcGIS the column types.
- `geo/property.kml` — opens in Google Earth.
- `media/photos/YYYY/MM/` — original photos, GPS in EXIF.
- `media/audio/YYYY/MM/` — voice notes (m4a); transcripts are in the notes.
- `reports/survival-summary.pdf` — every planting event with its latest survival.

Exported ${nowUtcIso()} by Field Notes. This export has no vendor
dependency; the data is yours.
''');
  }
}
