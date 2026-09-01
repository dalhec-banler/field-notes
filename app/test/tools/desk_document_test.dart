import 'dart:io';
import 'dart:ui' as ui;

import 'package:field_notes/db/database.dart';
import 'package:field_notes/export/map_docx.dart';
import 'package:field_notes/export/map_document.dart';
import 'package:field_notes/export/map_plate.dart';
import 'package:field_notes/export/map_report.dart';
import 'package:field_notes/export/plate_subject_loader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixture generator, not a test: writes map.png / map.pdf / map.docx for a
/// property database so the documents can be opened in real viewers.
///   flutter test test/tools/desk_document_test.dart \
///     --dart-define=FN_DB=/path/db.sqlite --dart-define=FN_DOC_OUT=/dir
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const dbPath = String.fromEnvironment('FN_DB');
  const out = String.fromEnvironment('FN_DOC_OUT');

  test('write desk documents', () async {
    if (dbPath.isEmpty || out.isEmpty) {
      markTestSkipped('FN_DB / FN_DOC_OUT not set');
      return;
    }
    final db = FieldNotesDb.fromFile(File(dbPath));
    final property = await (db.select(db.properties)..limit(1)).getSingle();
    final subject = await loadPlateSubject(db, property);
    await db.close();

    // Flutter tests have no network: a khaki tile stands in for imagery.
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 256, 256),
        ui.Paint()..color = const ui.Color(0xFF8A8F6A));
    final img = await rec.endRecording().toImage(256, 256);
    final tile = (await img.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();

    final plate = await MapPlate(fetchTile: (z, x, y) async => tile).render(
        subject,
        layers: const PlateLayers(records: true, tracks: true));
    final doc = MapDocument(
      title: property.name,
      plate: plate,
      subject: subject,
      layers: const PlateLayers(records: true, tracks: true),
      preparedFor: 'Texas Parks & Wildlife',
      notes: 'Zones as of September 2026. River strip planted spring 2025.\n'
          'Headcut in the basin needs rock before the fall rains.',
    );
    Directory(out).createSync(recursive: true);
    File('$out/map.png').writeAsBytesSync(plate.png);
    File('$out/map.pdf').writeAsBytesSync(await MapReport.build(doc));
    File('$out/map.docx').writeAsBytesSync(MapDocx.build(doc));
    expect(File('$out/map.docx').lengthSync(), greaterThan(10000));
  });
}
