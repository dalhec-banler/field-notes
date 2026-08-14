import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/export/exporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late FieldNotesDb db;
  late Directory tmp;
  late Property property;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    tmp = Directory.systemTemp.createTempSync('export');
    final now = nowUtcIso();
    final propId = newId();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
          id: propId,
          name: 'Shorts Resort',
          boundaryGeojson: const Value(
              '{"type":"Polygon","coordinates":[[[-98.2,31.0],[-98.1,31.0],[-98.1,31.1],[-98.2,31.1],[-98.2,31.0]]]}'),
          createdBy: 'austin',
          createdAt: now,
          updatedAt: now,
        ));
    property = await (db.select(db.properties)
          ..where((x) => x.id.equals(propId)))
        .getSingle();

    await db.into(db.zones).insert(ZonesCompanion.insert(
          id: newId(),
          propertyId: propId,
          name: 'Section 3',
          code: const Value('SFS-S3'),
          geojson:
              '{"type":"Polygon","coordinates":[[[-98.2,31.0],[-98.15,31.0],[-98.15,31.05],[-98.2,31.05],[-98.2,31.0]]]}',
          createdBy: 'austin',
          createdAt: now,
          updatedAt: now,
        ));

    await db.into(db.taxa).insert(TaxaCompanion.insert(
          id: newId(),
          scientificName: 'Salix nigra',
          commonName: const Value('Black Willow'),
          createdAt: now,
          updatedAt: now,
        ));

    for (var i = 0; i < 3; i++) {
      await db.into(db.observations).insert(ObservationsCompanion.insert(
            id: newId(),
            propertyId: propId,
            observedAt: now,
            localTz: 'CDT',
            lat: 31.02 + i * 0.001,
            lng: -98.18,
            notes: Value('note with, comma "and quotes" #$i'),
            createdBy: 'austin',
            createdAt: now,
            updatedAt: now,
          ));
    }
    // A soft-deleted record must NOT appear in exports.
    await db.into(db.observations).insert(ObservationsCompanion.insert(
          id: newId(),
          propertyId: propId,
          observedAt: now,
          localTz: 'CDT',
          lat: 31.09,
          lng: -98.11,
          deletedAt: Value(now),
          createdBy: 'austin',
          createdAt: now,
          updatedAt: now,
        ));
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  test('produces the full export layout with correct contents', () async {
    final dir = await Exporter(db).exportProperty(property, tmp);

    expect(dir.path, contains('shorts-resort-export-'));
    expect(File(p.join(dir.path, 'README.md')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'database.sqlite')).existsSync(), isTrue);
    expect(
        File(p.join(dir.path, 'database.sqlite')).lengthSync(), greaterThan(0));

    // CSV: header + 3 live rows, no tombstoned row; quoting survives.
    final obsCsv =
        File(p.join(dir.path, 'data', 'observations.csv')).readAsLinesSync();
    expect(obsCsv.length, 4);
    expect(obsCsv[1], contains('"note with, comma ""and quotes"" #'));

    // GeoJSON: valid FeatureCollection with 3 points.
    final obsGeo = jsonDecode(
            File(p.join(dir.path, 'geo', 'observations.geojson'))
                .readAsStringSync())
        as Map<String, dynamic>;
    expect(obsGeo['type'], 'FeatureCollection');
    expect((obsGeo['features'] as List).length, 3);
    final first = (obsGeo['features'] as List).first as Map<String, dynamic>;
    expect(first['geometry']['coordinates'][0], -98.18);

    final zonesGeo = jsonDecode(
            File(p.join(dir.path, 'geo', 'zones.geojson')).readAsStringSync())
        as Map<String, dynamic>;
    expect((zonesGeo['features'] as List).single['properties']['code'],
        'SFS-S3');

    // KML boundary present and coordinate order is lng,lat.
    final kml = File(p.join(dir.path, 'geo', 'property.kml')).readAsStringSync();
    expect(kml, contains('<Polygon>'));
    expect(kml, contains('-98.2,31.0,0'));

    // Global taxa rows are included for the taxa table.
    final taxaCsv =
        File(p.join(dir.path, 'data', 'taxa.csv')).readAsStringSync();
    expect(taxaCsv, contains('Salix nigra'));
  });

  test('exported sqlite is a valid database with the data', () async {
    final dir = await Exporter(db).exportProperty(property, tmp);
    final copy = FieldNotesDb.fromFile(
        File(p.join(dir.path, 'database.sqlite')));
    final rows = await copy.customSelect(
        'SELECT COUNT(*) AS n FROM observations WHERE deleted_at IS NULL').get();
    expect(rows.single.data['n'], 3);
    await copy.close();
  });
}
