import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../db/database.dart';

/// "Take my data" export (spec §6): one folder, open formats, no vendor
/// dependency. Layout mirrors the spec: database.sqlite + data/*.csv +
/// geo/*.geojson + property.kml + media/.
class Exporter {
  Exporter(this.db);

  final FieldNotesDb db;

  /// Exports [property] into [destRoot]; returns the export directory.
  Future<Directory> exportProperty(Property property, Directory destRoot) async {
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

    await _dumpDatabase(File(p.join(dir.path, 'database.sqlite')));
    await _writeCsvs(property.id, dataDir);
    await _writeGeojson(property.id, geoDir);
    _writeKml(property, File(p.join(geoDir.path, 'property.kml')));
    await _copyMedia(property.id, mediaDir);
    _writeReadme(property, File(p.join(dir.path, 'README.md')));
    return dir;
  }

  Future<void> _dumpDatabase(File out) async {
    // VACUUM INTO produces a clean, consistent single-file copy (spec §11.7).
    if (out.existsSync()) out.deleteSync();
    final path = out.path.replaceAll("'", "''");
    await db.customStatement("VACUUM INTO '$path'");
  }

  Future<void> _writeCsvs(String propertyId, Directory dataDir) async {
    Future<void> table(String name, {String? where}) async {
      final clause = where ?? "property_id = '$propertyId'";
      final rows = await db
          .customSelect('SELECT * FROM $name WHERE $clause AND deleted_at IS NULL'
              .replaceFirst(' AND deleted_at IS NULL',
                  _hasDeletedAt(name) ? ' AND deleted_at IS NULL' : ''))
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
    await table('taxa', where: "(property_id = '$propertyId' OR property_id IS NULL)");
    await table('detections');
    await table('practices');
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
      'observations.geojson',
      "SELECT o.*, t.scientific_name, t.common_name FROM observations o "
          "LEFT JOIN taxa t ON t.id = o.taxon_id "
          "WHERE o.property_id = '$propertyId' AND o.deleted_at IS NULL",
      (row) => {
        'type': 'Feature',
        'geometry': {
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

  Future<void> _copyMedia(String propertyId, Directory mediaDir) async {
    final rows = await (db.select(db.media)
          ..where((m) => m.propertyId.equals(propertyId))
          ..where((m) => m.deletedAt.isNull()))
        .get();
    for (final m in rows) {
      final src = m.localPath;
      if (src == null || !File(src).existsSync()) continue;
      final when = m.capturedAt ?? m.createdAt;
      final ym = when.substring(0, 7).split('-');
      final destDir = Directory(p.join(mediaDir.path, ym[0], ym[1]))
        ..createSync(recursive: true);
      File(src).copySync(p.join(destDir.path, '${m.id}${p.extension(src)}'));
    }
  }

  void _writeReadme(Property property, File out) {
    out.writeAsStringSync('''
# ${property.name} — Field Notes export

Everything your field journal knows about this place, in open formats.

- `database.sqlite` — the complete database. Open with any SQLite tool.
- `data/*.csv` — per-table exports for spreadsheets.
- `geo/*.geojson` — observations, zones, features, plantings, tracks.
  Open in QGIS, or drag onto geojson.io.
- `geo/property.kml` — opens in Google Earth.
- `media/photos/YYYY/MM/` — original photos.

Exported ${nowUtcIso()} by Field Notes. This export has no vendor
dependency; the data is yours.
''');
  }
}
