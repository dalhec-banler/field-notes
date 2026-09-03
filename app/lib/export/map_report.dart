import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'map_document.dart';

/// The printed map (D-024): a Letter page, map on top, legend and zone
/// table and notes below. Made to be attached to a grant report or handed
/// to a partner. For an editable version, see [MapDocx].
class MapReport {
  static const _ink = PdfColor.fromInt(0xFF1B1813);
  static const _soft = PdfColor.fromInt(0xFF6B655C);
  static const _rule = PdfColor.fromInt(0xFFB8AE9C);
  static const _oxblood = PdfColor.fromInt(0xFF8B2E22);

  /// The app's own faces, so '·' and '—' print instead of boxes (the PDF
  /// built-ins are WinAnsi-only). Tests skip this and accept the warning.
  static Future<pw.ThemeData> loadTheme() async {
    final base = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Newsreader-Regular.ttf'),
    );
    final bold = pw.Font.ttf(
      await rootBundle.load('assets/fonts/ZillaSlab-Bold.ttf'),
    );
    final italic = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Newsreader-Italic.ttf'),
    );
    return pw.ThemeData.withFont(base: base, bold: bold, italic: italic);
  }

  static Future<Uint8List> build(MapDocument d, {pw.ThemeData? theme}) async {
    final doc = pw.Document(
      title: d.title,
      author: 'Field Notes',
      theme: theme,
    );
    final image = pw.MemoryImage(d.plate.png);
    final legend = d.marksLegend;
    final half = (legend.length / 2).ceil();
    // Letter minus margins; the map takes the width and at most 55 % of the
    // height so the legend and notes start on the same page.
    final pageW = PdfPageFormat.letter.width - 96;
    final pageH = PdfPageFormat.letter.height - 96;
    final ratio = d.plate.height / d.plate.width;
    final mapH = (pageW * ratio).clamp(120.0, pageH * 0.55);
    final mapW = mapH / ratio;

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

    pw.Widget legendRow((int, String) e) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Row(
        children: [
          pw.Container(width: 9, height: 9, color: PdfColor.fromInt(e.$1)),
          pw.SizedBox(width: 6),
          pw.Expanded(
            child: pw.Text(e.$2, style: pw.TextStyle(fontSize: 9, color: _ink)),
          ),
        ],
      ),
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(48),
        footer: (ctx) => pw.Text(
          d.sourceLine,
          style: pw.TextStyle(fontSize: 7, color: _soft),
        ),
        build: (ctx) => [
          kicker('Field Notes · map'),
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
          pw.Text(d.subtitle, style: pw.TextStyle(fontSize: 9, color: _soft)),
          pw.SizedBox(height: 12),
          // Sized explicitly: the image must be told the page's width, or the
          // layout takes its pixel size as points and nothing fits.
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
          pw.SizedBox(height: 14),
          if (legend.isNotEmpty) ...[
            kicker('Legend'),
            pw.SizedBox(height: 6),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: pw.Column(
                    children: [for (final e in legend.take(half)) legendRow(e)],
                  ),
                ),
                pw.SizedBox(width: 16),
                pw.Expanded(
                  child: pw.Column(
                    children: [for (final e in legend.skip(half)) legendRow(e)],
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 12),
          ],
          if (d.zoneRowsInk.isNotEmpty) ...[
            kicker('Zones'),
            pw.SizedBox(height: 4),
            pw.Table(
              border: pw.TableBorder(
                horizontalInside: pw.BorderSide(color: _rule, width: 0.5),
              ),
              columnWidths: {
                0: const pw.FixedColumnWidth(16),
                1: const pw.FlexColumnWidth(4),
                2: const pw.FlexColumnWidth(1),
              },
              children: [
                for (final (ink, name, acres) in d.zoneRowsInk)
                  pw.TableRow(
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 4),
                        child: pw.Container(
                          width: 9,
                          height: 9,
                          color: PdfColor.fromInt(ink),
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 3),
                        child: pw.Text(
                          name,
                          style: pw.TextStyle(fontSize: 9, color: _ink),
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 3),
                        child: pw.Text(
                          acres,
                          textAlign: pw.TextAlign.right,
                          style: pw.TextStyle(fontSize: 9, color: _soft),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            pw.SizedBox(height: 12),
          ],
          if (d.featureRows.isNotEmpty) ...[
            kicker('Features'),
            pw.SizedBox(height: 4),
            pw.Table(
              border: pw.TableBorder(
                horizontalInside: pw.BorderSide(color: _rule, width: 0.5),
              ),
              columnWidths: {
                0: const pw.FlexColumnWidth(4),
                1: const pw.FlexColumnWidth(1.4),
              },
              children: [
                for (final (name, cls) in d.featureRows)
                  pw.TableRow(
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 3),
                        child: pw.Text(
                          name,
                          style: pw.TextStyle(fontSize: 9, color: _ink),
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 3),
                        child: pw.Text(
                          cls,
                          textAlign: pw.TextAlign.right,
                          style: pw.TextStyle(fontSize: 9, color: _soft),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            pw.SizedBox(height: 12),
          ],
          if (d.recordRows.isNotEmpty) ...[
            kicker('Field records on this map'),
            pw.SizedBox(height: 4),
            pw.Table(
              border: pw.TableBorder(
                horizontalInside: pw.BorderSide(color: _rule, width: 0.5),
              ),
              columnWidths: {
                0: const pw.FlexColumnWidth(4),
                1: const pw.FlexColumnWidth(1),
              },
              children: [
                for (final (label, count) in d.recordRows)
                  pw.TableRow(
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 3),
                        child: pw.Text(
                          label,
                          style: pw.TextStyle(fontSize: 9, color: _ink),
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 3),
                        child: pw.Text(
                          count,
                          textAlign: pw.TextAlign.right,
                          style: pw.TextStyle(fontSize: 9, color: _soft),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            pw.SizedBox(height: 12),
          ],
          if (d.notes != null && d.notes!.trim().isNotEmpty) ...[
            kicker('Notes'),
            pw.SizedBox(height: 6),
            pw.Text(
              d.notes!.trim(),
              style: pw.TextStyle(fontSize: 10, color: _ink, lineSpacing: 3),
            ),
          ],
        ],
      ),
    );
    return doc.save();
  }
}
