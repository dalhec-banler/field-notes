import 'field_defs.dart';

/// The seven shipped methods, lay name first, academic name in fine print.
///
/// Four are starters — the ones a landowner opens to. Three sit behind
/// "More methods". Planting survival stays in Grow › Plantings (D-018);
/// cameras and recorders stay in deployments (§4.12); photo points stay
/// where they are and any site here can make its stake one.
class ProtocolTemplate {
  const ProtocolTemplate({
    required this.methodKey,
    required this.name,
    required this.methodName,
    required this.reference,
    required this.siteKind,
    required this.cadenceDays,
    required this.seasonHint,
    required this.purpose,
    required this.carry,
    required this.steps,
    required this.fields,
    required this.computes,
    this.isStarter = false,
    this.defaultLengthM,
    this.defaultRadiusM,
  });

  final String methodKey;
  final String name;
  final String methodName;
  final String reference;

  /// 'point' | 'line' | 'plot' | 'route'
  final String siteKind;
  final int cadenceDays;
  final String seasonHint;

  /// One line: what it is for.
  final String purpose;

  /// What you carry.
  final String carry;

  /// What you do, in order.
  final List<String> steps;
  final List<FieldDef> fields;

  /// Indicator keys (lib/protocols/indicators.dart) shown for this method.
  final List<String> computes;
  final bool isStarter;
  final double? defaultLengthM;
  final double? defaultRadiusM;

  String get fieldsJson => encodeFields(fields);
}

const _sizeClasses = [
  ('seedling', 'Knee-high or less'),
  ('shrub', 'Knee to head'),
  ('tree', 'Taller than you'),
];

const _bands = [
  ('0_25', 'Close · under 25 m'),
  ('25_50', 'Middle · 25–50 m'),
  ('over_50', 'Far · over 50 m'),
];

const _sixCover = [
  FieldDef(
    key: 'grass',
    type: FieldType.class_,
    scale: 'daubenmire6',
    label: 'Grass',
    required: true,
  ),
  FieldDef(
    key: 'forb',
    type: FieldType.class_,
    scale: 'daubenmire6',
    label: 'Wildflowers & weeds',
    required: true,
  ),
  FieldDef(
    key: 'woody',
    type: FieldType.class_,
    scale: 'daubenmire6',
    label: 'Brush & trees',
    required: true,
  ),
  FieldDef(
    key: 'litter',
    type: FieldType.class_,
    scale: 'daubenmire6',
    label: 'Dead leaves & stems',
  ),
  FieldDef(
    key: 'bare',
    type: FieldType.class_,
    scale: 'daubenmire6',
    label: 'Bare dirt',
    required: true,
  ),
  FieldDef(
    key: 'rock',
    type: FieldType.class_,
    scale: 'daubenmire6',
    label: 'Rock',
  ),
  FieldDef(
    key: 'top_species',
    type: FieldType.taxa,
    maxCount: 3,
    label: 'Top three plants',
  ),
];

const _photo = FieldDef(
  key: 'photo',
  type: FieldType.photo,
  label: 'Photo down the tape',
);

const templates = <ProtocolTemplate>[
  ProtocolTemplate(
    methodKey: 'cover_check',
    name: 'Cover check',
    methodName: 'Daubenmire cover-class quadrats, 20 × 50 cm',
    reference: 'Daubenmire 1959; https://rangelandsgateway.org/inventorymonitoring/daubenmire',
    siteKind: 'line',
    defaultLengthM: 25,
    cadenceDays: 365,
    seasonHint: 'Late spring, and again after the first frost.',
    purpose: 'How much of the ground is grass, weeds, brush, or bare.',
    carry: 'A 20 × 50 cm frame (PVC works), a tape.',
    steps: [
      'Stand at the stake and run the tape out on the bearing.',
      'Drop the frame at 5, 10, 15, 20 and 25 m.',
      'In each frame, for each kind of ground, pick the picture that '
          'matches how much of the frame it covers.',
      'Name the top three plants. One photo down the tape.',
    ],
    fields: [
      FieldDef(
        key: 'quadrat',
        type: FieldType.group,
        repeat: 5,
        label: 'Frame',
        hint: 'Every 5 m along the tape',
        fields: _sixCover,
      ),
      _photo,
    ],
    computes: ['pct_grass', 'pct_forb', 'pct_woody', 'pct_litter', 'pct_bare'],
    isStarter: true,
  ),
  ProtocolTemplate(
    methodKey: 'brush_count',
    name: 'Brush count',
    methodName: 'Fixed-radius plot density by size class, 1/100 acre',
    reference:
        'Herrick et al. 2017 Vol. I, belt transect; NRCS 1/100-acre plot; '
        'TPWD 12-ft browse plot',
    siteKind: 'plot',
    defaultRadiusM: 3.59,
    cadenceDays: 365,
    seasonHint: 'Winter, when it is leaf-off and you can see stems.',
    purpose: 'How much brush is coming back, by species and size.',
    carry: 'A 3.6 m string tied to the stake, flagging.',
    steps: [
      'Walk the circle the string draws.',
      'For every woody plant rooted inside, tap its species and size.',
      'Count a clump of resprouts as one plant.',
      'Note browse on the ones the deer are hitting.',
    ],
    fields: [
      FieldDef(
        key: 'stems',
        type: FieldType.countByTaxon,
        label: 'Woody plants in the circle',
        by: 'size_class',
        byChoices: _sizeClasses,
        required: true,
      ),
      FieldDef(
        key: 'browsed',
        type: FieldType.class_,
        scale: 'severity4',
        label: 'Browse on them',
      ),
      FieldDef(
        key: 'canopy',
        type: FieldType.choice,
        label: 'Canopy overhead',
        choices: [('open', 'Open'), ('part', 'Part'), ('closed', 'Closed')],
      ),
      FieldDef(
        key: 'densiometer',
        type: FieldType.int_,
        label: 'Densiometer reading',
        hint: 'Only if you carry one · 0–96',
        min: 0,
        max: 96,
      ),
      FieldDef(key: 'photo', type: FieldType.photo, label: 'Photo of the plot'),
    ],
    computes: ['stems_per_acre', 'stems_per_acre_by_species'],
    isStarter: true,
  ),
  ProtocolTemplate(
    methodKey: 'cover_pole',
    name: 'Cover pole',
    methodName: 'Visual obstruction reading, Robel pole',
    reference:
        'Robel et al. 1970; NRCS NM Habitat Monitoring Protocol (VOR); '
        'https://wiki.landscapetoolbox.org/doku.php/field_methods:visual_obstruction_method',
    siteKind: 'point',
    cadenceDays: 180,
    seasonHint: 'A month before nesting (March) and after the growing season (October).',
    purpose: 'Whether the grass is tall enough to hide a nest.',
    carry: 'A banded 1.5 m pole, a 4 m string with a knot at 1 m.',
    steps: [
      'Stand the pole on the spot.',
      'Walk 4 m north on the string, crouch to the knot, and read the '
          'lowest band you can still see.',
      'Same from east, south and west.',
      'Eyeball the average grass height in a dinner-plate circle round '
          'the pole.',
    ],
    fields: [
      FieldDef(
        key: 'vor',
        type: FieldType.group,
        repeat: 4,
        fixed: ['North', 'East', 'South', 'West'],
        label: 'Reading',
        fields: [
          FieldDef(
            key: 'band_cm',
            type: FieldType.int_,
            label: 'Lowest band you can see',
            unit: 'cm',
            min: 0,
            max: 150,
            step: 5,
            required: true,
          ),
        ],
      ),
      FieldDef(
        key: 'avg_height_cm',
        type: FieldType.int_,
        label: 'Average grass height',
        unit: 'cm',
        min: 0,
        max: 300,
      ),
      FieldDef(key: 'photo', type: FieldType.photo, label: 'Photo of the pole'),
    ],
    computes: ['vor_mean_cm', 'nesting_cover'],
    isStarter: true,
  ),
  ProtocolTemplate(
    methodKey: 'bird_listen',
    name: 'Ten-minute listen',
    methodName: 'Fixed-radius point count, 10 min, 25/50 m bands',
    reference:
        'Matsuoka et al. 2014, Condor 116:599–608; USFWS point-count framework',
    siteKind: 'point',
    cadenceDays: 30,
    seasonHint: 'Sunrise to 10 am, April to June. Once in winter too.',
    purpose: 'Which birds use this spot, and how that changes.',
    carry: 'Binoculars. The phone.',
    steps: [
      'Stand still. Note the wind and sky.',
      'Start the ten-minute clock.',
      'Every bird you hear or see: tap its name and how far off it is.',
      'Fly-overs only count if they are using the place.',
    ],
    fields: [
      FieldDef(
        key: 'wind',
        type: FieldType.class_,
        scale: 'wind4',
        label: 'Wind',
        required: true,
      ),
      FieldDef(
        key: 'sky',
        type: FieldType.choice,
        label: 'Sky',
        choices: [
          ('clear', 'Clear'),
          ('cloudy', 'Cloudy'),
          ('drizzle', 'Drizzle'),
        ],
      ),
      FieldDef(
        key: 'noise',
        type: FieldType.choice,
        label: 'Background noise',
        choices: [('quiet', 'Quiet'), ('some', 'Some'), ('loud', 'Loud')],
      ),
      FieldDef(
        key: 'birds',
        type: FieldType.countByTaxon,
        label: 'Birds',
        by: 'band',
        byChoices: _bands,
        required: true,
      ),
      FieldDef(
        key: 'flyovers',
        type: FieldType.countByTaxon,
        label: 'Fly-overs',
      ),
    ],
    computes: ['richness', 'birds_total', 'birds_by_band'],
    isStarter: true,
  ),
  ProtocolTemplate(
    methodKey: 'pin_walk',
    name: 'Pin walk',
    methodName: 'Line-point intercept with soil-surface codes',
    reference: 'Herrick et al. 2017, Monitoring Manual Vol. I; BLM AIM / NRCS NRI core method',
    siteKind: 'line',
    defaultLengthM: 25,
    cadenceDays: 365,
    seasonHint: 'Peak growth, the same month each year.',
    purpose: 'The number a range scientist wants: cover by species, and bare ground.',
    carry: 'A 25 m tape, a straight pin (a length of welding rod).',
    steps: [
      'At every half-metre mark, drop the pin straight down.',
      'Tap the first plant it touches from the top, or "nothing".',
      'Tap anything else it touches on the way down.',
      'Tap what it hits on the ground: dirt, a plant base, dead leaves, rock, moss or crust.',
    ],
    fields: [
      FieldDef(
        key: 'point',
        type: FieldType.group,
        repeat: 50,
        label: 'Pin',
        hint: 'Every 0.5 m',
        fields: [
          FieldDef(
            key: 'top',
            type: FieldType.taxa,
            maxCount: 1,
            label: 'First plant it touches',
            hint: 'Leave empty for nothing',
          ),
          FieldDef(
            key: 'lower',
            type: FieldType.taxa,
            label: 'Anything else on the way down',
          ),
          FieldDef(
            key: 'surface',
            type: FieldType.choice,
            label: 'What it hits on the ground',
            required: true,
            choices: [
              ('S', 'Bare dirt'),
              ('basal', 'A plant base'),
              ('L', 'Dead leaves'),
              ('EL', 'Leaves pressed in the dirt'),
              ('R', 'Rock'),
              ('BR', 'Bedrock'),
              ('M', 'Moss'),
              ('LC', 'Lichen crust'),
              ('D', 'Duff'),
            ],
          ),
        ],
      ),
      FieldDef(
        key: 'gaps',
        type: FieldType.group,
        label: 'Gap between plants',
        hint: 'Optional: gaps of 20 cm or more along the tape',
        fields: [
          FieldDef(
            key: 'start_m',
            type: FieldType.real,
            label: 'Starts at',
            unit: 'm',
            required: true,
          ),
          FieldDef(
            key: 'end_m',
            type: FieldType.real,
            label: 'Ends at',
            unit: 'm',
            required: true,
          ),
        ],
      ),
      _photo,
    ],
    computes: [
      'pct_foliar',
      'pct_bare_ground',
      'pct_basal',
      'pct_litter',
      'pct_gaps_over_50cm',
      'cover_by_species',
    ],
  ),
  ProtocolTemplate(
    methodKey: 'soil_surface',
    name: 'Soil surface look',
    methodName: 'Erosion indicators, a subset of Interpreting Indicators of Rangeland Health',
    reference:
        'Pellant et al. 2020, IIRH v5; NRCS rangeland soil quality sheets',
    siteKind: 'plot',
    defaultRadiusM: 10,
    cadenceDays: 365,
    seasonHint: 'After the first big rain of the year.',
    purpose: 'Whether the soil is staying put.',
    carry: 'A ruler.',
    steps: [
      'Walk the circle slowly.',
      'For each sign, say none, a little, some, or a lot.',
      'Poke the ruler into the leaf litter in five spots.',
      'Take the photo. This one is mostly the picture.',
    ],
    fields: [
      FieldDef(
        key: 'rills',
        type: FieldType.class_,
        scale: 'severity4',
        label: 'Little channels cut by water',
        required: true,
      ),
      FieldDef(
        key: 'pedestals',
        type: FieldType.class_,
        scale: 'severity4',
        label: 'Plants sitting up on pedestals',
        required: true,
      ),
      FieldDef(
        key: 'flow_patterns',
        type: FieldType.class_,
        scale: 'severity4',
        label: 'Paths where water ran',
        required: true,
      ),
      FieldDef(
        key: 'litter_movement',
        type: FieldType.class_,
        scale: 'severity4',
        label: 'Leaves piled downhill of where they fell',
      ),
      FieldDef(
        key: 'bare_patches',
        type: FieldType.class_,
        scale: 'severity4',
        label: 'Bare patches bigger than a truck',
        required: true,
      ),
      FieldDef(
        key: 'crusting',
        type: FieldType.class_,
        scale: 'severity4',
        label: 'Crusted soil',
      ),
      FieldDef(
        key: 'litter',
        type: FieldType.group,
        repeat: 5,
        label: 'Litter depth',
        fields: [
          FieldDef(
            key: 'depth_mm',
            type: FieldType.int_,
            label: 'Depth',
            unit: 'mm',
            min: 0,
            max: 500,
            required: true,
          ),
        ],
      ),
      FieldDef(
        key: 'photo',
        type: FieldType.photo,
        label: 'Photo of the ground',
        required: true,
      ),
    ],
    computes: ['litter_depth_mean_mm', 'erosion_score'],
  ),
  ProtocolTemplate(
    methodKey: 'spotlight_drive',
    name: 'Spotlight drive',
    methodName: 'Spotlight survey on a fixed route',
    reference: 'TPWD PWD-RP-W7000-1126; TPWD Appendix A Census',
    siteKind: 'route',
    defaultLengthM: 5000,
    cadenceDays: 365,
    seasonHint: 'Three runs, August to October, same route, same speed.',
    purpose: 'How many deer, and does to bucks, fawns to does.',
    carry: 'A spotlight, a second person, the phone with a track running.',
    steps: [
      'Start the track at the gate.',
      'Drive the route at the same speed every time.',
      'Call every deer as buck, doe, fawn, or could not tell.',
      'At each marked stop, how far off the road you can see.',
    ],
    fields: [
      FieldDef(
        key: 'bucks',
        type: FieldType.int_,
        label: 'Bucks',
        min: 0,
        required: true,
      ),
      FieldDef(
        key: 'does',
        type: FieldType.int_,
        label: 'Does',
        min: 0,
        required: true,
      ),
      FieldDef(
        key: 'fawns',
        type: FieldType.int_,
        label: 'Fawns',
        min: 0,
        required: true,
      ),
      FieldDef(
        key: 'unknown',
        type: FieldType.int_,
        label: 'Could not tell',
        min: 0,
      ),
      FieldDef(
        key: 'visibility',
        type: FieldType.group,
        label: 'Stop',
        hint: 'How far off the road you can see, at each stop',
        fields: [
          FieldDef(
            key: 'visibility_m',
            type: FieldType.int_,
            label: 'Can see',
            unit: 'm',
            min: 0,
            max: 1000,
            required: true,
          ),
        ],
      ),
      FieldDef(
        key: 'other_animals',
        type: FieldType.countByTaxon,
        label: 'Other animals',
      ),
    ],
    computes: [
      'deer_total',
      'acres_sampled',
      'acres_per_deer',
      'does_per_buck',
      'fawns_per_doe',
    ],
  ),
];

ProtocolTemplate? templateFor(String methodKey) {
  for (final t in templates) {
    if (t.methodKey == methodKey) return t;
  }
  return null;
}

List<ProtocolTemplate> get starterTemplates =>
    templates.where((t) => t.isStarter).toList();

List<ProtocolTemplate> get moreTemplates =>
    templates.where((t) => !t.isStarter).toList();
