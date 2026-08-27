import 'package:field_notes/import/kml_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('waypoints, tracks and routes map to placemarks', () {
    final pms = parseGpx('''
<?xml version="1.0"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="31.05" lon="-98.15"><name>Spring</name><desc>flowing</desc><type>Water</type></wpt>
  <wpt lat="31.06" lon="-98.16"></wpt>
  <trk><name>Morning walk</name>
    <trkseg><trkpt lat="31.0" lon="-98.2"/><trkpt lat="31.01" lon="-98.19"/></trkseg>
    <trkseg><trkpt lat="31.02" lon="-98.18"/></trkseg>
  </trk>
  <rte><name>Fence line</name><rtept lat="31.0" lon="-98.1"/><rtept lat="31.1" lon="-98.1"/></rte>
  <trk><name>Too short</name><trkseg><trkpt lat="31.0" lon="-98.2"/></trkseg></trk>
</gpx>
''');
    expect(pms.length, 4);
    expect(pms[0].name, 'Spring');
    expect(pms[0].geometryType, 'Point');
    expect(pms[0].folder, 'Water');
    expect(pms[0].description, 'flowing');
    expect(pms[1].name, startsWith('Waypoint'));
    expect(pms[2].name, 'Morning walk');
    expect(pms[2].geometryType, 'LineString');
    expect(pms[2].geojson, contains('-98.18'), reason: 'segments joined');
    expect(pms[3].name, 'Fence line');
    expect(pms[3].folder, 'Routes');
  });
}
