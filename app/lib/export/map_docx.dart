import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'map_document.dart';

/// The editable map document (D-024): a real .docx — title, map, legend,
/// zone table, notes — that Word, Pages, LibreOffice and Google Docs open
/// as their own. Written by hand: WordprocessingML is a zip of XML and we
/// need five files and one picture, not a library.
class MapDocx {
  static const _emuPerInch = 914400;
  static const _pageWidthIn = 8.5, _pageHeightIn = 11.0, _marginIn = 0.9;

  static Uint8List build(MapDocument d) {
    final archive = Archive();
    void add(String path, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add('[Content_Types].xml', _contentTypes);
    add('_rels/.rels', _rootRels);
    add('word/_rels/document.xml.rels', _docRels);
    add('word/styles.xml', _styles);
    archive.addFile(
      ArchiveFile('word/media/map.png', d.plate.png.length, d.plate.png),
    );
    add('word/document.xml', _document(d));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static String _document(MapDocument d) {
    final usableIn = _pageWidthIn - 2 * _marginIn;
    var cx = (usableIn * _emuPerInch).round();
    var cy = (cx * d.plate.height / d.plate.width).round();
    // A tall plate keeps the legend on page one: cap at 5.8 in high.
    final maxCy = (5.8 * _emuPerInch).round();
    if (cy > maxCy) {
      cx = (cx * maxCy / cy).round();
      cy = maxCy;
    }
    final b = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>',
      )
      ..write(_p(d.title, style: 'Title'))
      ..write(_p(d.subtitle, style: 'Subtitle'))
      ..write(_picture(cx, cy))
      ..write(_p(''));
    if (d.marksLegend.isNotEmpty) {
      b.write(_p('Legend', style: 'Heading1'));
      b.write(_legendTable(d.marksLegend));
      b.write(_p(''));
    }
    if (d.zoneRowsInk.isNotEmpty) {
      b.write(_p('Zones', style: 'Heading1'));
      b.write(_zoneTable(d.zoneRowsInk));
      b.write(_p(''));
    }
    if (d.featureRows.isNotEmpty) {
      b.write(_p('Features', style: 'Heading1'));
      b.write(_pairTable(d.featureRows));
      b.write(_p(''));
    }
    if (d.recordRows.isNotEmpty) {
      b.write(_p('Field records on this map', style: 'Heading1'));
      b.write(_pairTable(d.recordRows));
      b.write(_p(''));
    }
    b.write(_p('Notes', style: 'Heading1'));
    final notes = (d.notes ?? '').trim();
    if (notes.isEmpty) {
      b.write(_p(''));
    } else {
      for (final line in notes.split('\n')) {
        b.write(_p(line));
      }
    }
    b.write(_p(''));
    b.write(_p(d.sourceLine, style: 'Fine'));
    final pw = (_pageWidthIn * 1440).round();
    final ph = (_pageHeightIn * 1440).round();
    final m = (_marginIn * 1440).round();
    b.write(
      '<w:sectPr><w:pgSz w:w="$pw" w:h="$ph"/>'
      '<w:pgMar w:top="$m" w:right="$m" w:bottom="$m" w:left="$m" w:header="720" w:footer="720" w:gutter="0"/>'
      '</w:sectPr></w:body></w:document>',
    );
    return b.toString();
  }

  static String _p(String text, {String? style}) {
    final ppr = style == null
        ? ''
        : '<w:pPr><w:pStyle w:val="$style"/></w:pPr>';
    final run = text.isEmpty
        ? ''
        : '<w:r><w:t xml:space="preserve">${_esc(text)}</w:t></w:r>';
    return '<w:p>$ppr$run</w:p>';
  }

  static String _picture(int cx, int cy) =>
      '<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
      '<wp:extent cx="$cx" cy="$cy"/><wp:effectExtent l="0" t="0" r="0" b="0"/>'
      '<wp:docPr id="1" name="Map"/>'
      '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
      '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="map.png"/>'
      '<pic:cNvPicPr><a:picLocks noChangeAspect="1"/></pic:cNvPicPr></pic:nvPicPr>'
      '<pic:blipFill><a:blip r:embed="rIdMap"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
      '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
      '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>';

  static String _legendTable(List<(int, String)> legend) {
    final b = StringBuffer(
      '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/>'
      '<w:tblLook w:val="0000"/></w:tblPr><w:tblGrid><w:gridCol w:w="400"/><w:gridCol w:w="4600"/>'
      '<w:gridCol w:w="400"/><w:gridCol w:w="4600"/></w:tblGrid>',
    );
    final half = (legend.length / 2).ceil();
    for (var i = 0; i < half; i++) {
      b.write('<w:tr>');
      for (final e in [
        legend[i],
        if (i + half < legend.length) legend[i + half],
      ]) {
        final hex = argbToCssHex(e.$1).substring(1);
        b.write(
          '<w:tc><w:tcPr><w:tcW w:w="400" w:type="dxa"/>'
          '<w:shd w:val="clear" w:color="auto" w:fill="$hex"/></w:tcPr>${_p('')}</w:tc>',
        );
        b.write(
          '<w:tc><w:tcPr><w:tcW w:w="4600" w:type="dxa"/></w:tcPr>${_p(e.$2)}</w:tc>',
        );
      }
      if (i + half >= legend.length) {
        b.write(
          '<w:tc><w:tcPr><w:tcW w:w="400" w:type="dxa"/></w:tcPr>${_p('')}</w:tc>'
          '<w:tc><w:tcPr><w:tcW w:w="4600" w:type="dxa"/></w:tcPr>${_p('')}</w:tc>',
        );
      }
      b.write('</w:tr>');
    }
    b.write('</w:tbl>');
    return b.toString();
  }

  static String _zoneTable(List<(int, String, String)> rows) {
    final b = StringBuffer(
      '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/>'
      '<w:tblBorders><w:insideH w:val="single" w:sz="4" w:space="0" w:color="B8AE9C"/>'
      '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="1B1813"/></w:tblBorders>'
      '<w:tblLook w:val="0000"/></w:tblPr><w:tblGrid><w:gridCol w:w="400"/>'
      '<w:gridCol w:w="7600"/><w:gridCol w:w="2000"/></w:tblGrid>',
    );
    for (final (ink, name, acres) in rows) {
      final hex = argbToCssHex(ink).substring(1);
      b.write(
        '<w:tr><w:tc><w:tcPr><w:tcW w:w="400" w:type="dxa"/>'
        '<w:shd w:val="clear" w:color="auto" w:fill="$hex"/></w:tcPr>${_p('')}</w:tc>'
        '<w:tc><w:tcPr><w:tcW w:w="7600" w:type="dxa"/></w:tcPr>${_p(name)}</w:tc>'
        '<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr>'
        '<w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>${_esc(acres)}</w:t></w:r></w:p></w:tc></w:tr>',
      );
    }
    b.write('</w:tbl>');
    return b.toString();
  }

  /// Plain two-column table (name · value), right column right-aligned —
  /// the features and records tables.
  static String _pairTable(List<(String, String)> rows) {
    final b = StringBuffer(
      '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/>'
      '<w:tblBorders><w:insideH w:val="single" w:sz="4" w:space="0" w:color="B8AE9C"/>'
      '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="1B1813"/></w:tblBorders>'
      '<w:tblLook w:val="0000"/></w:tblPr><w:tblGrid><w:gridCol w:w="8000"/><w:gridCol w:w="2000"/></w:tblGrid>',
    );
    for (final (name, value) in rows) {
      b.write(
        '<w:tr><w:tc><w:tcPr><w:tcW w:w="8000" w:type="dxa"/></w:tcPr>${_p(name)}</w:tc>'
        '<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr>'
        '<w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>${_esc(value)}</w:t></w:r></w:p></w:tc></w:tr>',
      );
    }
    b.write('</w:tbl>');
    return b.toString();
  }

  static String _esc(String s) => escapeXml(s);

  static const _contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="png" ContentType="image/png"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      '</Types>';

  static const _rootRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';

  static const _docRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '<Relationship Id="rIdMap" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/map.png"/>'
      '</Relationships>';

  static const _styles =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia" w:cs="Georgia"/><w:sz w:val="21"/></w:rPr></w:rPrDefault>'
      '<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
      '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:spacing w:after="40"/></w:pPr><w:rPr><w:b/><w:caps/><w:sz w:val="40"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:spacing w:after="200"/></w:pPr><w:rPr><w:color w:val="6B655C"/><w:sz w:val="18"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>'
      '<w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/></w:pPr><w:rPr><w:b/><w:caps/><w:color w:val="8B2E22"/><w:sz w:val="18"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Fine"><w:name w:val="Fine"/><w:basedOn w:val="Normal"/>'
      '<w:rPr><w:color w:val="6B655C"/><w:sz w:val="15"/></w:rPr></w:style>'
      '</w:styles>';
}
