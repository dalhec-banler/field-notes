import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:field_notes/export/map_docx.dart';
import 'package:field_notes/export/map_document.dart';
import 'package:field_notes/export/map_html.dart';
import 'package:field_notes/export/map_plate.dart';
import 'package:field_notes/export/map_report.dart';
import 'package:field_notes/export/plate_subject_loader.dart';
import 'package:field_notes/export/web_mercator.dart';
import 'package:flutter_test/flutter_test.dart';

/// The desk's export plate (D-024): framing follows the layers you chose,
/// coincident records collapse to a counted badge, missing imagery is
/// counted (never faked), and the HTML twin embeds exactly the same data.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String poly(List<List<double>> lnglat) => jsonEncode({
    'type': 'Polygon',
    'coordinates': [
      [...lnglat, lnglat.first],
    ],
  });

  final boundary = poly([
    [-98.06, 31.05],
    [-98.03, 31.05],
    [-98.03, 31.07],
    [-98.06, 31.07],
  ]);
  final zoneA = poly([
    [-98.055, 31.055],
    [-98.045, 31.055],
    [-98.045, 31.065],
    [-98.055, 31.065],
  ]);
  final subject = PlateSubject(
    propertyName: 'Test Place',
    boundaryGeojson: boundary,
    zones: [PlateZone(name: 'River strip', geojson: zoneA, areaAcres: 12.5)],
    features: const [
      PlateFeature(
        name: 'Spring',
        featureClass: 'natural',
        geojson: '{"type":"Point","coordinates":[-98.05,31.06]}',
      ),
    ],
    records: const [
      PlateRecord(lat: 31.058, lng: -98.052, type: 'plant', label: 'Live oak'),
      PlateRecord(lat: 31.058, lng: -98.052, type: 'plant', label: 'Live oak'),
      PlateRecord(lat: 31.058001, lng: -98.052001, type: 'problem'),
      PlateRecord(lat: 31.066, lng: -98.036, type: 'water'),
    ],
    tracks: const [
      PlateTrack(
        geojson: '{"type":"LineString","coordinates":[[-98.058,31.052],[-98.04,31.066]]}',
      ),
    ],
  );

  Future<Uint8List> solidTile(int argb) async {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      const ui.Rect.fromLTWH(0, 0, 256, 256),
      ui.Paint()..color = ui.Color(argb),
    );
    final img = await rec.endRecording().toImage(256, 256);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  test('frame follows the boundary when drawn, the layers when not', () {
    final withBoundary = MapPlate.frameBounds(
      subject,
      const PlateLayers(boundary: true),
    );
    expect(withBoundary.west, lessThan(-98.06));
    expect(withBoundary.east, greaterThan(-98.03));
    final zonesOnly = MapPlate.frameBounds(
      subject,
      const PlateLayers(
        boundary: false,
        features: false,
        records: false,
        tracks: false,
      ),
    );
    // Zone A is well inside the boundary: the frame tightens to it.
    expect(zonesOnly.west, greaterThan(-98.06));
    expect(zonesOnly.east, lessThan(-98.03));
  });

  test('coincident records collapse into one counted group', () {
    final b = MapPlate.frameBounds(subject, const PlateLayers(records: true));
    final frame = PlateFrame(bounds: b, zoom: 16);
    final groups = MapPlate.groupOverlapping(frame, subject.records);
    expect(groups.length, 2);
    expect(groups.map((g) => g.$2.length).toList()..sort(), [1, 3]);
  });

  test(
    'renders a PNG, counts missing tiles, and legends what it drew',
    () async {
      var calls = 0;
      final tile = await solidTile(0xFF6A7B5A);
      final plate = MapPlate(
        fetchTile: (z, x, y) async {
          calls++;
          // Every third tile "missing" — the plate paints paper and says so.
          return calls % 3 == 0 ? null : tile;
        },
      );
      final r = await plate.render(
        subject,
        layers: const PlateLayers(records: true, tracks: true),
        maxWidth: 900,
        maxHeight: 700,
      );
      expect(r.png.length, greaterThan(1000));
      expect(r.png.sublist(1, 4), utf8.encode('PNG'));
      // Supersampled 2x.
      expect(r.width, lessThanOrEqualTo(1800));
      expect(r.width, greaterThan(900));
      expect(r.height, lessThanOrEqualTo(1400));
      expect(r.tilesMissing, greaterThan(0));
      expect(r.overlapGroups, 1);
      final labels = r.legend.map((e) => e.$2).toList();
      expect(labels.first, 'Property boundary');
      expect(labels, contains('River strip'));
      expect(labels, contains('Walked track'));
      expect(labels, contains('Natural feature'));
      // Every plant record sat in the overlap group, so the badge speaks for
      // them and the only singleton type legended is water.
      expect(labels, contains('Water record'));
      expect(labels, isNot(contains('Plant record')));
      expect(labels, contains('Several records at one spot'));
    },
  );

  test(
    'records off by default: nothing with a coordinate of a record leaves',
    () async {
      final tile = await solidTile(0xFF6A7B5A);
      final plate = MapPlate(fetchTile: (z, x, y) async => tile);
      final r = await plate.render(subject, maxWidth: 600, maxHeight: 600);
      expect(r.overlapGroups, 0);
      expect(r.legend.map((e) => e.$2), isNot(contains('Plant record')));
    },
  );

  test('HTML twin embeds the same layers and withholds records by default', () {
    final html = MapHtml.build(subject);
    expect(html, contains('<title>Test Place</title>'));
    expect(html, contains('River strip'));
    expect(html, contains('Property boundary'));
    expect(html, contains('maplibre-gl@${MapHtml.maplibreVersion}'));
    expect(html, contains(usgsImageryTemplate));
    expect(html, isNot(contains('Live oak')));
    expect(html, isNot(contains('31.058')));
    final withRecords = MapHtml.build(
      subject,
      layers: const PlateLayers(records: true),
    );
    expect(withRecords, contains('Live oak'));
    expect(withRecords, contains('cluster: true'));
  });

  test('HTML escapes a hostile place name', () {
    final s = PlateSubject(propertyName: '<script>alert(1)</script> & Co');
    final html = MapHtml.build(s);
    expect(html, isNot(contains('<script>alert')));
    expect(html, contains('&lt;script&gt;'));
  });

  test(
    'PDF and Word documents carry the same map, legend, zones, notes',
    () async {
      final tile = await solidTile(0xFF6A7B5A);
      final plate = MapPlate(fetchTile: (z, x, y) async => tile);
      final r = await plate.render(subject, maxWidth: 500, maxHeight: 400);
      final d = MapDocument(
        title: 'Test Place',
        plate: r,
        subject: subject,
        layers: const PlateLayers(),
        preparedFor: 'TPWD',
        notes: 'Riparian strip planted 2025.\nSecond line.',
      );
      final pdf = await MapReport.build(d);
      expect(pdf.length, greaterThan(2000));
      expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');

      final docx = MapDocx.build(d);
      final zip = ZipDecoder().decodeBytes(docx);
      final names = zip.files.map((f) => f.name).toList();
      expect(
        names,
        containsAll([
          '[Content_Types].xml',
          'word/document.xml',
          'word/styles.xml',
          'word/media/map.png',
          'word/_rels/document.xml.rels',
        ]),
      );
      final xml = utf8.decode(
        zip.findFile('word/document.xml')!.content as List<int>,
      );
      expect(xml, contains('Test Place'));
      expect(xml, contains('Prepared for TPWD'));
      expect(xml, contains('River strip'));
      expect(xml, contains('12.5 ac'));
      expect(xml, contains('Riparian strip planted 2025.'));
      expect(xml, contains('r:embed="rIdMap"'));
      expect(xml, contains('record locations are not shown'));
      final png = zip.findFile('word/media/map.png')!.content as List<int>;
      expect(png.length, r.png.length);
    },
  );

  test('acresOf: a 1 km × 1 km square near 31°N is about 247 acres', () {
    // 1 km in latitude ≈ 0.008993°, in longitude at 31.06°N ≈ 0.010497°.
    final sq = poly([
      [-98.06, 31.06],
      [-98.06 + 0.010497, 31.06],
      [-98.06 + 0.010497, 31.06 + 0.008993],
      [-98.06, 31.06 + 0.008993],
    ]);
    expect(acresOf(sq)!, closeTo(247.1, 2.5));
    expect(acresOf('{"type":"Point","coordinates":[0,0]}'), isNull);
  });
}
