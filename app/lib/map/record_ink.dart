/// One mark table for records everywhere (design audit 2026-09-03, P1-3).
///
/// The phone map, the printed plate, the HTML export, and the list rows
/// were speaking three colour dialects — the same record a different hue
/// on each surface. This file is the single home: **shape says what kind
/// of thing** (grown/observed = circle, built = square, trouble =
/// triangle), **colour says domain**, and each surface supplies only its
/// own halo (paper stroke on the phone's record layer, white on print).
///
/// Zero imports on purpose: pure data any layer may read.
library;

enum RecordShape { circle, square, triangle }

class RecordMark {
  const RecordMark(this.argb, this.shape);
  final int argb;
  final RecordShape shape;
}

const recordMarks = <String, RecordMark>{
  'plant': RecordMark(0xFF4E6B4A, RecordShape.circle), // sage, unnamed plant
  'phenology': RecordMark(0xFF7A8C3B, RecordShape.circle), // moss
  'wildlife': RecordMark(0xFFA8791F, RecordShape.circle), // ochre
  'sign': RecordMark(0xFFC29A4B, RecordShape.circle), // ochre, lighter
  'water': RecordMark(0xFF2F5D8A, RecordShape.circle), // river
  'soil': RecordMark(0xFF7A5C3B, RecordShape.circle), // umber
  'general': RecordMark(0xFF6B655C, RecordShape.circle), // warm gray
  'infrastructure': RecordMark(0xFF1B1813, RecordShape.square), // ink
  'maintenance': RecordMark(0xFFA8791F, RecordShape.square), // work: attention
  'problem': RecordMark(0xFF8B2E22, RecordShape.triangle), // oxblood
  'survey': RecordMark(0xFF2F5D8A, RecordShape.square), // monitoring run (D-033)
  // Legacy rows only — 'weather' left kObservationTypes in v4.
  'weather': RecordMark(0xFF2F5D8A, RecordShape.circle),
};

RecordMark markFor(String type) => recordMarks[type] ?? recordMarks['general']!;

/// Named plants colour by growth form — trees, shrubs, grasses and forbs
/// read apart at a glance. The phone map keys its `kind` property on these.
const growthFormInk = <String, int>{
  'tree': 0xFF3F5957,
  'shrub': 0xFF5F6B58,
  'graminoid': 0xFFB58A3C,
  'forb': 0xFF8E6A28,
  'vine': 0xFF5C7A78,
  'succulent': 0xFF8E9B85,
  'fern': 0xFF6B8F71,
  'moss': 0xFF6B8F71,
};

/// D-027: the ring around a record flagged for removal — a signal red, not
/// the press's oxblood, so it reads on imagery at a glance (Austin,
/// 2026-09-07: "a red ring around the green dot"). The dot inside keeps
/// saying what the plant is.
const removalRed = 0xFFE0261C;

String cssHex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// The MapLibre `match` expression for the phone's record-dot colour:
/// growth forms first, then the type marks, warm-gray fallback. Built here
/// so the screen palette cannot drift from the shared table.
List<Object> kindColorMatch() => [
  'match',
  ['get', 'kind'],
  for (final e in growthFormInk.entries) ...[e.key, cssHex(e.value)],
  for (final e in recordMarks.entries) ...[e.key, cssHex(e.value.argb)],
  cssHex(recordMarks['general']!.argb),
];

/// The section taxonomy (Austin, 2026-09-04: "we should have separate
/// sections for species, infra, problems"): a record with a species name
/// belongs to SPECIES wherever records are listed; the rest of the circle
/// types are field observations; squares are the built estate; triangles
/// are trouble.
enum RecordRealm { species, observation, infrastructure, problem }

RecordRealm realmOfType(String type) => switch (type) {
  'problem' => RecordRealm.problem,
  'infrastructure' || 'maintenance' => RecordRealm.infrastructure,
  _ => RecordRealm.observation,
};

const realmTitles = {
  RecordRealm.species: 'Species',
  RecordRealm.observation: 'Observations',
  RecordRealm.infrastructure: 'Infrastructure',
  RecordRealm.problem: 'Problems',
};
