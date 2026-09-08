import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'map_document.dart';
import 'map_plate.dart';

/// The contractor's sheet (D-027): the property plate with every record
/// flagged for removal as a numbered oxblood pin, a legend, a count by
/// species, then the numbered list — photo, species, nativity, where it
/// stands, when it was seen, what was noted. Hand it over and say "these".
class RemovalPlan {
  static const _ink = PdfColor.fromInt(PlateInk.ink);
  static const _soft = PdfColor.fromInt(0xFF6B655C);
  static const _rule = PdfColor.fromInt(0xFFB8AE9C);
  static const _oxblood = PdfColor.fromInt(PlateInk.oxblood);
  static const _paper = PdfColor.fromInt(PlateInk.paper);

  static PdfColor _nativityInk(String? n) => switch (n) {
    'native' => const PdfColor.fromInt(PlateInk.sage),
    'introduced' => const PdfColor.fromInt(PlateInk.ochre),
    'invasive' => _oxblood,
    _ => _soft,
  };

  static Future<Uint8List> build(MapDocument d, {pw.ThemeData? theme}) async {
    final rows = d.numbered;
    final doc = pw.Document(
      title: '${d.title} — removal plan',
      author: 'Field Notes',
      theme: theme,
    );
    final image = pw.MemoryImage(d.plate.png);
    final format = PdfPageFormat(d.page.widthPt, d.page.heightPt);
    final margin = d.page == PlatePage.poster ? 72.0 : 48.0;
    final pageW = format.width - 2 * margin;
    final pageH = format.height - 2 * margin;
    final ratio = d.plate.height / d.plate.width;
    final mapH = (pageW * ratio).clamp(120.0, pageH * 0.6);
    final mapW = mapH / ratio;

    // Photos read once, thumbnails where the phone made them; a missing
    // file is a blank frame, never a failed sheet.
    final photos = <int, pw.MemoryImage>{};
    for (var i = 0; i < rows.length; i++) {
      final path = rows[i].photoPath;
      if (path == null) continue;
      try {
        final f = File(path);
        if (f.existsSync()) photos[i] = pw.MemoryImage(f.readAsBytesSync());
      } catch (_) {}
    }

    // Count by species, most first.
    final bySpecies = <String, (int, String?)>{};
    for (final r in rows) {
      final key = r.label ?? '${_cap(r.type)} record';
      final prev = bySpecies[key];
      bySpecies[key] = ((prev?.$1 ?? 0) + 1, r.nativity ?? prev?.$2);
    }
    final speciesRows = bySpecies.entries.toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));

    pw.Widget kicker(String s) => pw.Row(
      children: [
        pw.Container(width: 14, height: 2, color: _oxblood),
        pw.SizedBox(width: 6),
        pw.Text(
          s.toUpperCase(),
          style: pw.TextStyle(fontSize: 7.5, letterSpacing: 1.6, color: _soft),
        ),
      ],
    );
    pw.Widget pin(String label, {double size = 18}) => pw.Container(
      width: size,
      height: size,
      alignment: pw.Alignment.center,
      decoration: const pw.BoxDecoration(
        color: _oxblood,
        shape: pw.BoxShape.circle,
      ),
      child: pw.Text(
        label,
        style: pw.TextStyle(
          fontSize: label.length >= 3 ? 6.5 : 8,
          fontWeight: pw.FontWeight.bold,
          color: _paper,
        ),
      ),
    );
    pw.Widget nativity(String? n) => n == null
        ? pw.SizedBox()
        : pw.Container(
            padding: const pw.EdgeInsets.symmetric(
              horizontal: 5,
              vertical: 1.5,
            ),
            decoration: pw.BoxDecoration(
              color: _nativityInk(n),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Text(
              n.toUpperCase(),
              style: pw.TextStyle(fontSize: 6, letterSpacing: 1, color: _paper),
            ),
          );

    pw.Widget line(int i) {
      final r = rows[i];
      final photo = photos[i];
      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 6),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.6)),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pin('${i + 1}', size: 20),
            pw.SizedBox(width: 8),
            pw.Container(
              width: 54,
              height: 54,
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: _rule, width: 0.6),
              ),
              child: photo == null
                  ? pw.Center(
                      child: pw.Text(
                        'no photo',
                        style: pw.TextStyle(fontSize: 6, color: _soft),
                      ),
                    )
                  : pw.Image(photo, fit: pw.BoxFit.cover),
            ),
            pw.SizedBox(width: 10),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Row(
                    children: [
                      pw.Text(
                        r.label ?? '${_cap(r.type)} record',
                        style: pw.TextStyle(
                          fontSize: 10.5,
                          fontWeight: pw.FontWeight.bold,
                          color: _ink,
                        ),
                      ),
                      pw.SizedBox(width: 6),
                      nativity(r.nativity),
                    ],
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    '${r.lat.toStringAsFixed(5)}, ${r.lng.toStringAsFixed(5)}'
                    '${r.observedAt != null ? ' · seen ${r.observedAt!.substring(0, 10)}' : ''}',
                    style: pw.TextStyle(fontSize: 7.5, color: _soft),
                  ),
                  if (r.notes != null && r.notes!.trim().isNotEmpty) ...[
                    pw.SizedBox(height: 3),
                    pw.Text(
                      r.notes!.trim(),
                      style: pw.TextStyle(fontSize: 8.5, color: _ink),
                      maxLines: 4,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: pw.EdgeInsets.all(margin),
        footer: (ctx) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              d.sourceLine,
              style: pw.TextStyle(fontSize: 7, color: _soft),
            ),
            pw.Text(
              '${ctx.pageNumber} / ${ctx.pagesCount}',
              style: pw.TextStyle(fontSize: 7, color: _soft),
            ),
          ],
        ),
        build: (ctx) => [
          kicker('Field Notes · removal plan'),
          pw.SizedBox(height: 4),
          pw.Text(
            d.title.toUpperCase(),
            style: pw.TextStyle(
              fontSize: 20,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            '${rows.length} record${rows.length == 1 ? '' : 's'} flagged for '
            'removal · ${d.subtitle}',
            style: pw.TextStyle(fontSize: 9, color: _soft),
          ),
          pw.SizedBox(height: 12),
          pw.SizedBox(
            width: mapW,
            height: mapH,
            child: pw.Container(
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: _ink, width: 1),
              ),
              child: pw.Image(
                image,
                width: mapW - 2,
                height: mapH - 2,
                fit: pw.BoxFit.fill,
              ),
            ),
          ),
          pw.SizedBox(height: 12),
          kicker('Legend'),
          pw.SizedBox(height: 6),
          pw.Row(
            children: [
              pin('1'),
              pw.SizedBox(width: 6),
              pw.Text(
                'A record flagged for removal — the number is its line below.',
                style: pw.TextStyle(fontSize: 9, color: _ink),
              ),
            ],
          ),
          if (d.plate.overlapGroups > 0) ...[
            pw.SizedBox(height: 4),
            pw.Row(
              children: [
                pin('1+2'),
                pw.SizedBox(width: 6),
                pw.Text(
                  'More flagged records at the same spot — the next lines.',
                  style: pw.TextStyle(fontSize: 9, color: _ink),
                ),
              ],
            ),
          ],
          if (speciesRows.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            kicker('By species'),
            pw.SizedBox(height: 4),
            pw.Table(
              columnWidths: {
                0: const pw.FlexColumnWidth(),
                1: const pw.FixedColumnWidth(80),
                2: const pw.FixedColumnWidth(40),
              },
              children: [
                for (final e in speciesRows)
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(
                      border: pw.Border(
                        bottom: pw.BorderSide(color: _rule, width: 0.5),
                      ),
                    ),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 3),
                        child: pw.Text(
                          e.key,
                          style: pw.TextStyle(fontSize: 9, color: _ink),
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 3),
                        child: pw.Align(
                          alignment: pw.Alignment.centerLeft,
                          child: nativity(e.value.$2),
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 3),
                        child: pw.Text(
                          '${e.value.$1}',
                          textAlign: pw.TextAlign.right,
                          style: pw.TextStyle(fontSize: 9, color: _soft),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
          pw.SizedBox(height: 12),
          kicker('The list'),
          pw.SizedBox(height: 4),
          if (rows.isEmpty)
            pw.Text(
              'Nothing is flagged for removal on this place.',
              style: pw.TextStyle(fontSize: 9, color: _soft),
            )
          else
            for (var i = 0; i < rows.length; i++) line(i),
          if ((d.notes ?? '').trim().isNotEmpty) ...[
            pw.SizedBox(height: 12),
            kicker('Notes'),
            pw.SizedBox(height: 4),
            pw.Text(
              d.notes!.trim(),
              style: pw.TextStyle(fontSize: 9.5, color: _ink, lineSpacing: 2),
            ),
          ],
        ],
      ),
    );
    return doc.save();
  }

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}
