import 'dart:convert';
import 'dart:math' as math;

import 'field_defs.dart';

/// What a run's answers add up to — derived on read, never stored.
///
/// Percent cover, stems per acre, the mean pole reading, richness: the
/// numbers a conservationist or a course wants, computed from
/// `values_json` the way survival is computed from check-ins (CLAUDE.md
/// rule 6). Each indicator carries a lay label and a unit; the wide CSV
/// export writes them as columns.
class Indicator {
  const Indicator(this.key, this.label, this.value, this.unit, {this.detail});

  final String key;
  final String label;
  final double? value;
  final String unit;

  /// Fine print or a per-species breakdown, for the detail screen.
  final String? detail;

  String get display {
    final v = value;
    if (v == null) return '—';
    return switch (unit) {
      'pct' => '${v.round()} %',
      'per_acre' => '${v.round()}/ac',
      'cm' => '${v.round()} cm',
      'mm' => '${v.round()} mm',
      'count' => '${v.round()}',
      'acres' => v.toStringAsFixed(1),
      'ratio' => v.toStringAsFixed(2),
      _ => v.toStringAsFixed(1),
    };
  }
}

const sqMPerAcre = 4046.8564224;

/// Sample area of a site, in acres — a circle for plots, a 2 m belt for a
/// line (Herrick's small-shrub belt), null when there is nothing to divide by.
double? siteAreaAcres({
  required String siteKind,
  double? radiusM,
  double? lengthM,
}) {
  if (siteKind == 'plot' && radiusM != null && radiusM > 0) {
    return math.pi * radiusM * radiusM / sqMPerAcre;
  }
  if (siteKind == 'line' && lengthM != null && lengthM > 0) {
    return lengthM * 2 / sqMPerAcre;
  }
  return null;
}

/// Names to show for taxon ids in per-species breakdowns.
typedef TaxonNamer = String Function(String taxonId);

List<Indicator> computeIndicators({
  required String methodKey,
  required String valuesJson,
  required String siteKind,
  double? radiusM,
  double? lengthM,
  TaxonNamer? nameOf,
}) {
  final Map<String, dynamic> v;
  try {
    v = (jsonDecode(valuesJson) as Map).cast<String, dynamic>();
  } catch (_) {
    return const [];
  }
  String name(String id) => nameOf?.call(id) ?? id;
  return switch (methodKey) {
    'cover_check' => _coverCheck(v),
    'brush_count' => _brushCount(v, siteKind, radiusM, lengthM, name),
    'cover_pole' => _coverPole(v),
    'bird_listen' => _birdListen(v, name),
    'pin_walk' => _pinWalk(v, lengthM, name),
    'soil_surface' => _soilSurface(v),
    'spotlight_drive' => _spotlight(v, lengthM),
    _ => const [],
  };
}

List<Map<String, dynamic>> _samples(Map<String, dynamic> v, String key) {
  final raw = v[key];
  if (raw is! List) return const [];
  return [
    for (final s in raw)
      if (s is Map) s.cast<String, dynamic>(),
  ];
}

double? _mean(Iterable<double> xs) {
  var n = 0;
  var sum = 0.0;
  for (final x in xs) {
    n++;
    sum += x;
  }
  return n == 0 ? null : sum / n;
}

int _int(Object? x) => x is num ? x.round() : int.tryParse('$x') ?? 0;

/// Rows of {taxon_id, count, by?}.
List<({String taxon, int count, String? by})> _counts(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final r in raw)
      if (r is Map && r['taxon_id'] != null)
        (
          taxon: '${r['taxon_id']}',
          count: _int(r['count']),
          by: r['by'] == null ? null : '${r['by']}',
        ),
  ];
}

List<Indicator> _coverCheck(Map<String, dynamic> v) {
  final frames = _samples(v, 'quadrat');
  const kinds = [
    ('grass', 'Grass'),
    ('forb', 'Wildflowers & weeds'),
    ('woody', 'Brush & trees'),
    ('litter', 'Dead leaves & stems'),
    ('bare', 'Bare dirt'),
  ];
  return [
    for (final (key, label) in kinds)
      Indicator(
        'pct_$key',
        label,
        _mean([
          for (final f in frames)
            if (f[key] != null) classValue('daubenmire6', f[key])!,
        ]),
        'pct',
        detail: 'Daubenmire midpoints, ${frames.length} frames',
      ),
  ];
}

List<Indicator> _brushCount(
  Map<String, dynamic> v,
  String siteKind,
  double? radiusM,
  double? lengthM,
  TaxonNamer name,
) {
  final acres = siteAreaAcres(
    siteKind: siteKind,
    radiusM: radiusM,
    lengthM: lengthM,
  );
  final rows = _counts(v['stems']);
  final total = rows.fold<int>(0, (a, r) => a + r.count);
  final bySpecies = <String, int>{};
  for (final r in rows) {
    bySpecies[r.taxon] = (bySpecies[r.taxon] ?? 0) + r.count;
  }
  final ranked = bySpecies.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final perAcre = acres == null || acres == 0 ? null : total / acres;
  return [
    Indicator(
      'stems_per_acre',
      'Woody plants per acre',
      perAcre,
      'per_acre',
      detail: acres == null
          ? '$total counted, plot size unknown'
          : '$total in ${(acres * sqMPerAcre).round()} m²',
    ),
    Indicator(
      'stems_per_acre_by_species',
      'By species',
      ranked.isEmpty || acres == null ? null : ranked.first.value / acres,
      'per_acre',
      detail: [
        for (final e in ranked)
          '${name(e.key)}: ${acres == null ? e.value : (e.value / acres).round()}'
              '${acres == null ? '' : '/ac'}',
      ].join(' · '),
    ),
  ];
}

List<Indicator> _coverPole(Map<String, dynamic> v) {
  final readings = _samples(v, 'vor');
  final mean = _mean([
    for (final r in readings)
      if (r['band_cm'] != null) _int(r['band_cm']).toDouble(),
  ]);
  String? reading;
  if (mean != null) {
    reading = mean < 10
        ? 'too short for a quail nest'
        : mean < 25
        ? 'thin nesting cover'
        : 'nesting cover';
  }
  return [
    Indicator(
      'vor_mean_cm',
      'Cover pole, average',
      mean,
      'cm',
      detail: '${readings.length} directions',
    ),
    Indicator('nesting_cover', 'What that means', mean, 'cm', detail: reading),
  ];
}

List<Indicator> _birdListen(Map<String, dynamic> v, TaxonNamer name) {
  final rows = _counts(v['birds']);
  final species = {for (final r in rows) r.taxon};
  final total = rows.fold<int>(0, (a, r) => a + r.count);
  final byBand = <String, int>{};
  for (final r in rows) {
    byBand[r.by ?? '?'] = (byBand[r.by ?? '?'] ?? 0) + r.count;
  }
  return [
    Indicator('richness', 'Kinds of bird', species.length.toDouble(), 'count'),
    Indicator('birds_total', 'Birds counted', total.toDouble(), 'count'),
    Indicator(
      'birds_by_band',
      'By distance',
      (byBand['0_25'] ?? 0).toDouble(),
      'count',
      detail:
          'close ${byBand['0_25'] ?? 0} · middle ${byBand['25_50'] ?? 0} · '
          'far ${byBand['over_50'] ?? 0}',
    ),
  ];
}

List<Indicator> _pinWalk(
  Map<String, dynamic> v,
  double? lengthM,
  TaxonNamer name,
) {
  final pins = _samples(v, 'point');
  final n = pins.length;
  if (n == 0) return const [];
  var foliar = 0, bare = 0, basal = 0, litter = 0;
  final topBySpecies = <String, int>{};
  for (final p in pins) {
    final top = p['top'];
    final topId = top is List && top.isNotEmpty
        ? '${top.first}'
        : top is String && top.isNotEmpty
        ? top
        : null;
    final lower = p['lower'];
    final hasLower = lower is List && lower.isNotEmpty;
    final surface = '${p['surface'] ?? ''}';
    if (topId != null) {
      foliar++;
      topBySpecies[topId] = (topBySpecies[topId] ?? 0) + 1;
    }
    if (topId == null && !hasLower && surface == 'S') bare++;
    if (surface == 'basal') basal++;
    if (surface == 'L' || surface == 'EL') litter++;
  }
  double pct(int x) => x * 100 / n;
  // Gaps: share of the tape in gaps over 50 cm.
  double? gapPct;
  if (lengthM != null && lengthM > 0) {
    var covered = 0.0;
    for (final g in _samples(v, 'gaps')) {
      final s = (g['start_m'] as num?)?.toDouble();
      final e = (g['end_m'] as num?)?.toDouble();
      if (s == null || e == null) continue;
      final len = (e - s).abs();
      if (len >= 0.5) covered += len;
    }
    gapPct = covered * 100 / lengthM;
  }
  final ranked = topBySpecies.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return [
    Indicator(
      'pct_foliar',
      'Plants overhead',
      pct(foliar),
      'pct',
      detail: '$n pins',
    ),
    Indicator('pct_bare_ground', 'Bare ground', pct(bare), 'pct'),
    Indicator('pct_basal', 'Plant bases', pct(basal), 'pct'),
    Indicator('pct_litter', 'Dead leaves on the ground', pct(litter), 'pct'),
    Indicator('pct_gaps_over_50cm', 'Tape in gaps over 50 cm', gapPct, 'pct'),
    Indicator(
      'cover_by_species',
      'Top plant',
      ranked.isEmpty ? null : pct(ranked.first.value),
      'pct',
      detail: [
        for (final e in ranked) '${name(e.key)} ${pct(e.value).round()} %',
      ].join(' · '),
    ),
  ];
}

List<Indicator> _soilSurface(Map<String, dynamic> v) {
  final depths = [
    for (final s in _samples(v, 'litter'))
      if (s['depth_mm'] != null) _int(s['depth_mm']).toDouble(),
  ];
  const signs = [
    'rills',
    'pedestals',
    'flow_patterns',
    'litter_movement',
    'bare_patches',
    'crusting',
  ];
  final scores = [
    for (final k in signs)
      if (v[k] != null) classValue('severity4', v[k]) ?? 0,
  ];
  return [
    Indicator(
      'litter_depth_mean_mm',
      'Leaf litter depth',
      _mean(depths),
      'mm',
      detail: '${depths.length} pokes',
    ),
    Indicator(
      'erosion_score',
      'Erosion signs',
      scores.isEmpty ? null : scores.fold<double>(0, (a, b) => a + b),
      'count',
      detail: '0 is none, ${signs.length * 3} is every sign at its worst',
    ),
  ];
}

List<Indicator> _spotlight(Map<String, dynamic> v, double? lengthM) {
  final bucks = _int(v['bucks']);
  final does = _int(v['does']);
  final fawns = _int(v['fawns']);
  final unknown = _int(v['unknown']);
  final deer = bucks + does + fawns + unknown;
  final vis = _mean([
    for (final s in _samples(v, 'visibility'))
      if (s['visibility_m'] != null) _int(s['visibility_m']).toDouble(),
  ]);
  double? acres;
  if (lengthM != null && lengthM > 0 && vis != null) {
    acres = lengthM * vis * 2 / sqMPerAcre;
  }
  return [
    Indicator('deer_total', 'Deer seen', deer.toDouble(), 'count'),
    Indicator(
      'acres_sampled',
      'Acres you could see',
      acres,
      'acres',
      detail: vis == null
          ? 'no visibility stops'
          : 'route × ${vis.round()} m each side',
    ),
    Indicator(
      'acres_per_deer',
      'Acres per deer',
      acres == null || deer == 0 ? null : acres / deer,
      'acres',
    ),
    Indicator(
      'does_per_buck',
      'Does per buck',
      bucks == 0 ? null : does / bucks,
      'ratio',
    ),
    Indicator(
      'fawns_per_doe',
      'Fawns per doe',
      does == 0 ? null : fawns / does,
      'ratio',
    ),
  ];
}
