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
    this.preparedFor,
    this.notes,
    DateTime? date,
  }) : _date = date;

  final String title;
  final PlateResult plate;
  final PlateSubject subject;
  final PlateLayers layers;
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

  /// The plain statement of what the map shows and where it came from.
  String get sourceLine =>
      'Imagery: USGS The National Map (public domain), zoom ${plate.zoom}. '
      '${layers.records ? 'Field record locations are shown.' : 'Field record locations are not shown.'}'
      '${plate.tilesMissing > 0 ? ' ${plate.tilesMissing} imagery tiles were unavailable.' : ''}'
      ' Made with Field Notes.';
}
