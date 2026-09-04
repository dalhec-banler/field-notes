import '../map/imagery_sources.dart';
import '../map/record_ink.dart';
import 'map_plate.dart';

/// What the exported document says, independent of format (D-024). The PDF
/// and the Word file are two renderings of this one thing, so what you
/// proof in one is what the other says.
class MapDocument {
  const MapDocument({
    required this.title,
    required this.plate,
    required this.subject,
    required this.layers,
    this.species,
    this.preparedFor,
    this.notes,
    DateTime? date,
  }) : _date = date;

  final String title;
  final PlateResult plate;
  final PlateSubject subject;
  final PlateLayers layers;

  /// Species mode (matches what [MapPlate.render] drew): the chosen
  /// species, in their plate colours.
  final List<PlateSpecies>? species;
  final String? preparedFor;
  final String? notes;
  final DateTime? _date;

  DateTime get date => _date ?? DateTime.now();

  String get dateLine {
    final d = date;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String get subtitle => [
    dateLine,
    if (preparedFor != null && preparedFor!.trim().isNotEmpty)
      'Prepared for ${preparedFor!.trim()}',
  ].join(' · ');

  /// Zone rows for the table: (name, acres label).
  List<(String, String)> get zoneRows => [
    if (layers.zones)
      for (final z in subject.zones)
        (
          z.name,
          z.areaAcres == null ? '—' : '${z.areaAcres!.toStringAsFixed(1)} ac',
        ),
  ];

  /// Zone rows with their drawn colour, so the table itself is the zone
  /// legend (swatch · name · acres) and the legend proper keeps only marks.
  List<(int, String, String)> get zoneRowsInk => [
    if (layers.zones)
      for (var i = 0; i < subject.zones.length; i++)
        (
          MapPlate.zoneInk(subject.zones[i], i),
          subject.zones[i].name,
          subject.zones[i].areaAcres == null
              ? '—'
              : '${subject.zones[i].areaAcres!.toStringAsFixed(1)} ac',
        ),
  ];

  /// The legend without the per-zone rows (those live in the zone table
  /// now): boundary, tracks, feature classes, record types.
  List<(int, String)> get marksLegend {
    final zoneNames = {for (final z in subject.zones) z.name};
    return [
      for (final e in plate.legend)
        if (!zoneNames.contains(e.$2)) e,
    ];
  }

  /// The map shows features; the document must name them (name · class).
  List<(String, String)> get featureRows => [
    if (layers.features)
      for (final f in subject.features)
        (
          f.name,
          switch (f.featureClass) {
            'problem' => 'Problem',
            'infrastructure' => 'Infrastructure',
            _ => 'Natural',
          },
        ),
  ];

  /// What the record dots are: species (or type) · count, most first.
  List<(String, String)> get recordRows {
    if (!layers.records) return const [];
    final sel = species;
    if (sel != null && sel.isNotEmpty) {
      return [
        for (final s in sel)
          (
            s.label,
            '${subject.records.where((r) => (r.label ?? '__type:${r.type}') == s.key).length}',
          ),
      ];
    }
    // Species first, then observations, the built, the broken — the same
    // sections every panel uses (2026-09-04).
    final counts = <String, (int, int)>{};
    for (final r in subject.records) {
      final key =
          r.label ?? '${r.type[0].toUpperCase()}${r.type.substring(1)} record';
      final realm = r.label != null ? RecordRealm.species : realmOfType(r.type);
      final prev = counts[key];
      counts[key] = (realm.index, (prev?.$2 ?? 0) + 1);
    }
    final rows = counts.entries.toList()
      ..sort((a, b) {
        final byRealm = a.value.$1.compareTo(b.value.$1);
        return byRealm != 0 ? byRealm : b.value.$2.compareTo(a.value.$2);
      });
    return [for (final e in rows) (e.key, '${e.value.$2}')];
  }

  /// The plain statement of what the map shows and where it came from.
  String get sourceLine =>
      'Imagery: ${activeImagery.attribution}, zoom ${plate.zoom}. '
      '${layers.records ? 'Field record locations are shown.' : 'Field record locations are not shown.'}'
      '${plate.tilesMissing > 0 ? ' ${plate.tilesMissing} imagery tiles were unavailable.' : ''}'
      ' Made with Field Notes.';
}

/// XML/HTML entity escaping shared by the DOCX and HTML renderers — the
/// same four entities, one home.
String escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// `#RRGGBB` for an ARGB int — the print palette's colours as CSS/OOXML hex.
String argbToCssHex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
