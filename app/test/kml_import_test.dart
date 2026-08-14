import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:field_notes/import/kml_import.dart';
import 'package:flutter_test/flutter_test.dart';

const _kml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
  <name>SFS</name>
  <Folder>
    <name>Boundary</name>
    <Placemark>
      <name>Property boundary</name>
      <Polygon>
        <outerBoundaryIs><LinearRing><coordinates>
          -98.20,31.00,0 -98.10,31.00,0 -98.10,31.10,0 -98.20,31.10,0 -98.20,31.00,0
        </coordinates></LinearRing></outerBoundaryIs>
      </Polygon>
    </Placemark>
  </Folder>
  <Folder>
    <name>Features</name>
    <Placemark>
      <name>Spring</name>
      <description>Perennial seep</description>
      <Point><coordinates>-98.15,31.05,312</coordinates></Point>
    </Placemark>
    <Placemark>
      <name>Fence line</name>
      <LineString><coordinates>-98.20,31.00 -98.15,31.02 -98.10,31.00</coordinates></LineString>
    </Placemark>
    <Placemark>
      <name>Two pastures</name>
      <MultiGeometry>
        <Polygon><outerBoundaryIs><LinearRing><coordinates>
          -98.19,31.01 -98.18,31.01 -98.18,31.02 -98.19,31.02 -98.19,31.01
        </coordinates></LinearRing></outerBoundaryIs></Polygon>
        <Polygon><outerBoundaryIs><LinearRing><coordinates>
          -98.13,31.01 -98.12,31.01 -98.12,31.02 -98.13,31.02 -98.13,31.01
        </coordinates></LinearRing></outerBoundaryIs></Polygon>
      </MultiGeometry>
    </Placemark>
    <Placemark>
      <name>No geometry</name>
    </Placemark>
  </Folder>
</Document>
</kml>''';

void main() {
  test('parses polygons, points, lines, multigeometry; skips empty', () {
    final pms = parseKml(_kml);
    expect(pms.length, 4);

    final boundary = pms.firstWhere((p) => p.name == 'Property boundary');
    expect(boundary.geometryType, 'Polygon');
    expect(boundary.folder, 'SFS/Boundary');
    final ring =
        (jsonDecode(boundary.geojson)['coordinates'] as List).first as List;
    expect(ring.length, 5);
    expect(ring.first, [-98.20, 31.00]); // lng,lat order, altitude dropped

    final spring = pms.firstWhere((p) => p.name == 'Spring');
    expect(spring.geometryType, 'Point');
    expect(spring.description, 'Perennial seep');
    expect(jsonDecode(spring.geojson)['coordinates'], [-98.15, 31.05]);

    final fence = pms.firstWhere((p) => p.name == 'Fence line');
    expect(fence.geometryType, 'LineString');

    final pastures = pms.firstWhere((p) => p.name == 'Two pastures');
    expect(pastures.geometryType, 'MultiPolygon');
    expect((jsonDecode(pastures.geojson)['coordinates'] as List).length, 2);
  });

  test('KMZ round-trip', () {
    final archive = Archive()
      ..addFile(ArchiveFile('doc.kml', _kml.length, utf8.encode(_kml)));
    final kmz = Uint8List.fromList(ZipEncoder().encode(archive));
    final pms = parseKmz(kmz);
    expect(pms.length, 4);
  });

  test('KMZ without a kml entry throws FormatException', () {
    final archive = Archive()
      ..addFile(ArchiveFile('readme.txt', 2, utf8.encode('hi')));
    final kmz = Uint8List.fromList(ZipEncoder().encode(archive));
    expect(() => parseKmz(kmz), throwsFormatException);
  });
}
