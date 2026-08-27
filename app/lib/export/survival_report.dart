
import 'package:drift/drift.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../db/database.dart';
import '../services/survival.dart';

/// `reports/survival-summary.pdf` (spec §6): one page per property — every
/// planting event with its latest survival figure, plus totals. Built with
/// the pure-Dart `pdf` package so it runs on the host in tests.
class SurvivalReport {
  SurvivalReport(this.db);

  final FieldNotesDb db;

  Future<Uint8List> build(Property property) async {
    final events = await (db.select(db.plantingEvents)
          ..where((e) => e.propertyId.equals(property.id))
          ..where((e) => e.deletedAt.isNull())
          ..orderBy([(e) => OrderingTerm.desc(e.plantedOn)]))
        .get();
    final taxa = {
      for (final t in await db.select(db.taxa).get()) t.id: t
    };
    final zones = {
      for (final z in await (db.select(db.zones)
            ..where((z) => z.propertyId.equals(property.id)))
          .get())
        z.id: z.name
    };

    final rows = <List<String>>[];
    var planted = 0;
    var aliveKnown = 0;
    var plantedKnown = 0;
    for (final e in events) {
      final t = e.taxonId == null ? null : taxa[e.taxonId];
      final s = await survivalFor(db, e);
      planted += e.countPlanted;
      if (s != null && !s.fromTags) {
        aliveKnown += s.alive;
        plantedKnown += s.total;
      }
      rows.add([
        e.plantedOn,
        t == null
            ? '—'
            : (t.commonName != null
                ? '${t.commonName} (${t.scientificName})'
                : t.scientificName),
        e.zoneId == null ? '—' : (zones[e.zoneId] ?? '—'),
        '${e.countPlanted}',
        e.stockSource.replaceAll('_', ' '),
        s == null ? 'no check-in yet' : s.summary,
      ]);
    }

    final generated = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${generated.year}-${two(generated.month)}-${two(generated.day)}';

    final doc = pw.Document(
      title: '${property.name} — survival summary',
      author: 'Field Notes',
    );
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(40),
        build: (ctx) => [
          pw.Text(property.name.toUpperCase(),
              style: pw.TextStyle(
                  fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          pw.Text('Planting survival summary · generated $stamp',
              style: const pw.TextStyle(fontSize: 10)),
          pw.SizedBox(height: 16),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              _stat('Planting events', '${events.length}'),
              _stat('Plants planted', '$planted'),
              _stat(
                  'Cohort survival',
                  plantedKnown == 0
                      ? '—'
                      : '${(aliveKnown / plantedKnown * 100).toStringAsFixed(0)}%'),
              _stat('Checked', '$aliveKnown of $plantedKnown'),
            ],
          ),
          pw.SizedBox(height: 18),
          if (rows.isEmpty)
            pw.Text('No planting events recorded yet.')
          else
            pw.TableHelper.fromTextArray(
              headers: const [
                'Planted',
                'Species',
                'Zone',
                'Count',
                'Stock',
                'Latest survival',
              ],
              data: rows,
              headerStyle:
                  pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellAlignments: {3: pw.Alignment.centerRight},
              border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
              headerDecoration:
                  const pw.BoxDecoration(color: PdfColors.grey300),
            ),
          pw.SizedBox(height: 18),
          pw.Text(
            'Survival is derived, never stored: cohort figures are the latest '
            'check-in\'s alive count over the number planted; "tagged" figures '
            'count only individually tagged plants. Source data: '
            'data/planting_events.csv, data/plant_checkins.csv, data/plants.csv.',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ],
      ),
    );
    return doc.save();
  }

  pw.Widget _stat(String label, String value) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(value,
              style: pw.TextStyle(
                  fontSize: 18, fontWeight: pw.FontWeight.bold)),
          pw.Text(label, style: const pw.TextStyle(fontSize: 9)),
        ],
      );
}
