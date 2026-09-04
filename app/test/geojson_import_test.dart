import 'package:field_notes/import/kml_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FeatureCollection maps to placemarks with names and folders', () {
    final pms = parseGeoJson('''
{
  "type": "FeatureCollection",
  "features": [
    {"type": "Feature", "properties": {"name": "Boundary"},
     "geometry": {"type": "Polygon", "coordinates": [[[-98.2,31.0],[-98.1,31.0],[-98.1,31.1],[-98.2,31.0]]]}},
    {"type": "Feature", "properties": {"Name": "Spring", "layer": "Features"},
     "geometry": {"type": "Point", "coordinates": [-98.15, 31.05]}},
    {"type": "Feature", "properties": {},
     "geometry": {"type": "MultiPoint", "coordinates": [[-98.1,31.0],[-98.11,31.01]]}},
    {"type": "Feature", "properties": {"name": "skip me"}, "geometry": null}
  ]
}
''');
    expect(pms.length, 4, reason: 'polygon + point + 2 multipoint parts');
    expect(pms[0].name, 'Boundary');
    expect(pms[0].geometryType, 'Polygon');
    expect(pms[1].name, 'Spring');
    expect(pms[1].folder, 'Features');
    expect(pms[2].geometryType, 'Point');
    expect(pms[2].name, endsWith(' 1'));
    expect(pms[3].name, endsWith(' 2'));
  });

  test('bare geometry and single Feature are accepted', () {
    expect(
      parseGeoJson('{"type":"Point","coordinates":[-98,31]}')
          .single
          .geometryType,
      'Point',
    );
    expect(
      parseGeoJson(
        '{"type":"Feature","properties":{"title":"T"},"geometry":{"type":"LineString","coordinates":[[-98,31],[-98.1,31.1]]}}',
      ).single.name,
      'T',
    );
  });

  test('non-object input is a FormatException', () {
    expect(() => parseGeoJson('[1,2]'), throwsFormatException);
  });
}
