/// One candidate identification, from any source.
class IdCandidate {
  IdCandidate({
    required this.name,
    required this.source,
    this.commonName,
    this.score,
    this.reasoning,
    this.taxonId,
    this.rank,
  });

  /// Scientific name as the source returned it.
  final String name;
  final String? commonName;

  /// `plantnet` | `on_device` | `llm_rerank` — matches the schema's CHECK.
  final String source;

  /// 0..1 where the source gives one.
  final double? score;

  /// Why this candidate, in the re-ranker's words. Shown to the user.
  final String? reasoning;

  /// Set when the name matched a taxon already in the library.
  final String? taxonId;

  final int? rank;

  IdCandidate copyWith({
    String? source,
    double? score,
    String? reasoning,
    String? taxonId,
    int? rank,
    String? commonName,
  }) => IdCandidate(
    name: name,
    commonName: commonName ?? this.commonName,
    source: source ?? this.source,
    score: score ?? this.score,
    reasoning: reasoning ?? this.reasoning,
    taxonId: taxonId ?? this.taxonId,
    rank: rank ?? this.rank,
  );

  String get displayName => commonName == null ? name : '$commonName ($name)';
}

/// The context a re-ranker gets that no vision model has: where you are,
/// what month it is, what the ground is, and what you've already recorded
/// here. This is the whole argument for the re-rank step.
class IdContext {
  const IdContext({
    required this.propertyName,
    this.county,
    this.state,
    this.lat,
    this.lng,
    this.zoneName,
    this.zoneType,
    this.soilSeries,
    this.soilDrainage,
    this.month,
    this.recordedHere = const [],
    this.plantedHere = const [],
  });

  final String propertyName;
  final String? county;
  final String? state;
  final double? lat;
  final double? lng;
  final String? zoneName;
  final String? zoneType;
  final String? soilSeries;
  final String? soilDrainage;

  /// 1–12, the month the photograph was taken.
  final int? month;

  /// Species already recorded on this property.
  final List<String> recordedHere;

  /// Species deliberately planted here — a strong prior.
  final List<String> plantedHere;

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// Plain prose for the model. Coordinates are rounded to ~1 km: the
  /// re-ranker needs the region, not the plant's exact location, and this
  /// is the one place record data leaves the phone.
  String describe() {
    final b = StringBuffer();
    b.writeln('Place: $propertyName');
    if (county != null || state != null) {
      b.writeln(
        'County/state: ${[county, state].whereType<String>().join(", ")}',
      );
    }
    if (lat != null && lng != null) {
      b.writeln(
        'Approximate location: '
        '${lat!.toStringAsFixed(2)}, ${lng!.toStringAsFixed(2)}',
      );
    }
    if (zoneName != null) {
      b.writeln('Zone: $zoneName${zoneType != null ? " ($zoneType)" : ""}');
    }
    if (soilSeries != null) {
      b.writeln(
        'Soil: $soilSeries'
        '${soilDrainage != null ? ", $soilDrainage" : ""}',
      );
    }
    if (month != null && month! >= 1 && month! <= 12) {
      b.writeln('Month: ${_months[month! - 1]}');
    }
    if (plantedHere.isNotEmpty) {
      b.writeln('Planted on this property: ${plantedHere.join(", ")}');
    }
    if (recordedHere.isNotEmpty) {
      b.writeln(
        'Already recorded on this property: '
        '${recordedHere.take(60).join(", ")}',
      );
    }
    return b.toString();
  }
}
