import 'dart:convert';

/// The questions a protocol asks, and the scales its answers use.
///
/// A protocol's `fields_json` is a list of these. The type list is closed:
/// a custom protocol picks from it, never extends it, so every screen and
/// every export knows how to draw and how to number an answer.
///
/// Lay wording lives in [label] and [hint]; the academic name of a class
/// scale lives on the scale, in fine print.
enum FieldType {
  /// Whole number, optional min/max/unit.
  int_,

  /// Decimal number.
  real,

  /// One class from a named ordinal scale (Daubenmire, Braun-Blanquet…).
  class_,

  /// One of the protocol's own choices.
  choice,

  /// Yes / no.
  bool_,

  /// Free text.
  text,

  /// One or more species from the library.
  taxa,

  /// Rows of {taxon_id, count}, optionally split by a `by` dimension.
  countByTaxon,

  /// A photograph (media id).
  photo,

  /// A repeated block of fields: N samples, or as many as you see.
  group,
}

FieldType _typeFrom(String s) => switch (s) {
  'int' => FieldType.int_,
  'real' => FieldType.real,
  'class' => FieldType.class_,
  'choice' => FieldType.choice,
  'bool' => FieldType.bool_,
  'text' => FieldType.text,
  'taxa' => FieldType.taxa,
  'count_by_taxon' => FieldType.countByTaxon,
  'photo' => FieldType.photo,
  'group' => FieldType.group,
  _ => throw FormatException('Unknown protocol field type "$s"'),
};

String typeName(FieldType t) => switch (t) {
  FieldType.int_ => 'int',
  FieldType.real => 'real',
  FieldType.class_ => 'class',
  FieldType.choice => 'choice',
  FieldType.bool_ => 'bool',
  FieldType.text => 'text',
  FieldType.taxa => 'taxa',
  FieldType.countByTaxon => 'count_by_taxon',
  FieldType.photo => 'photo',
  FieldType.group => 'group',
};

class FieldDef {
  const FieldDef({
    required this.key,
    required this.type,
    required this.label,
    this.hint,
    this.required = false,
    this.scale,
    this.choices = const [],
    this.min,
    this.max,
    this.step,
    this.unit,
    this.maxCount,
    this.by,
    this.byChoices = const [],
    this.repeat,
    this.fields = const [],
    this.fixed = const [],
  });

  final String key;
  final FieldType type;
  final String label;
  final String? hint;
  final bool required;

  /// For [FieldType.class_]: a key into [scales].
  final String? scale;

  /// For [FieldType.choice]: (value, label).
  final List<(String, String)> choices;

  final num? min;
  final num? max;
  final num? step;
  final String? unit;

  /// For [FieldType.taxa]: how many at most.
  final int? maxCount;

  /// For [FieldType.countByTaxon]: the dimension each count is split by
  /// (`size_class`, `band`), and its (value, label) choices.
  final String? by;
  final List<(String, String)> byChoices;

  /// For [FieldType.group]: a sample count, or null for "as many as you
  /// see" (open).
  final int? repeat;
  final List<FieldDef> fields;

  /// For a group whose samples are named in advance (N/E/S/W): one label
  /// per sample, in order.
  final List<String> fixed;

  bool get isOpenGroup => type == FieldType.group && repeat == null;

  /// Every required key inside a group sample (or the top level).
  List<FieldDef> get requiredFields => fields.where((f) => f.required).toList();

  static FieldDef fromJson(Map<String, dynamic> j) {
    List<(String, String)> pairs(Object? v) => [
      for (final c in (v as List? ?? const []))
        c is List
            ? ('${c[0]}', '${c[1]}')
            : c is Map
            ? ('${c['value']}', '${c['label']}')
            : ('$c', '$c'),
    ];
    return FieldDef(
      key: j['key'] as String,
      type: _typeFrom(j['type'] as String),
      label: j['label'] as String? ?? j['key'] as String,
      hint: j['hint'] as String?,
      required: j['required'] == true,
      scale: j['scale'] as String?,
      choices: pairs(j['choices']),
      min: j['min'] as num?,
      max: j['max'] as num?,
      step: j['step'] as num?,
      unit: j['unit'] as String?,
      maxCount: j['max_count'] as int?,
      by: j['by'] as String?,
      byChoices: pairs(j['by_choices']),
      repeat: j['repeat'] is int ? j['repeat'] as int : null,
      fields: [
        for (final f in (j['fields'] as List? ?? const []))
          FieldDef.fromJson(f as Map<String, dynamic>),
      ],
      fixed: [for (final f in (j['fixed'] as List? ?? const [])) '$f'],
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'type': typeName(type),
    'label': label,
    if (hint != null) 'hint': hint,
    if (required) 'required': true,
    if (scale != null) 'scale': scale,
    if (choices.isNotEmpty)
      'choices': [
        for (final c in choices) [c.$1, c.$2],
      ],
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (step != null) 'step': step,
    if (unit != null) 'unit': unit,
    if (maxCount != null) 'max_count': maxCount,
    if (by != null) 'by': by,
    if (byChoices.isNotEmpty)
      'by_choices': [
        for (final c in byChoices) [c.$1, c.$2],
      ],
    if (type == FieldType.group) 'repeat': repeat ?? 'open',
    if (fields.isNotEmpty) 'fields': [for (final f in fields) f.toJson()],
    if (fixed.isNotEmpty) 'fixed': fixed,
  };
}

List<FieldDef> parseFields(String fieldsJson) => [
  for (final f in jsonDecode(fieldsJson) as List)
    FieldDef.fromJson(f as Map<String, dynamic>),
];

String encodeFields(List<FieldDef> fields) =>
    jsonEncode([for (final f in fields) f.toJson()]);

/// A named ordinal scale: what the chips say, what the fine print says,
/// and the number each class stands for at export time.
class ClassScale {
  const ClassScale({
    required this.key,
    required this.methodName,
    required this.unit,
    required this.classes,
  });

  final String key;

  /// Fine print: 'Daubenmire cover class'.
  final String methodName;

  /// What [ClassStep.value] is in: 'pct_cover_midpoint', 'class'.
  final String unit;
  final List<ClassStep> classes;

  ClassStep? byCode(Object? code) {
    if (code == null) return null;
    final c = '$code';
    for (final s in classes) {
      if (s.code == c) return s;
    }
    return null;
  }

  /// The number an answer stands for, or null when unanswered.
  double? valueOf(Object? code) => byCode(code)?.value;
}

class ClassStep {
  const ClassStep(this.code, this.label, this.value, {this.detail});

  /// Stored in values_json.
  final String code;

  /// The lay chip.
  final String label;

  /// Its number (a midpoint, a severity rank).
  final double value;

  /// Fine print: '25–50 %'.
  final String? detail;
}

const scales = <String, ClassScale>{
  'daubenmire6': ClassScale(
    key: 'daubenmire6',
    methodName: 'Daubenmire cover class',
    unit: 'pct_cover_midpoint',
    classes: [
      ClassStep('1', 'A trace', 2.5, detail: '0–5 %'),
      ClassStep('2', 'A little', 15, detail: '5–25 %'),
      ClassStep('3', 'Some', 37.5, detail: '25–50 %'),
      ClassStep('4', 'Half or more', 62.5, detail: '50–75 %'),
      ClassStep('5', 'Most of it', 85, detail: '75–95 %'),
      ClassStep('6', 'All of it', 97.5, detail: '95–100 %'),
    ],
  ),
  'braun_blanquet': ClassScale(
    key: 'braun_blanquet',
    methodName: 'Braun-Blanquet cover-abundance',
    unit: 'pct_cover_midpoint',
    classes: [
      ClassStep('r', 'One plant', 0.01, detail: 'solitary'),
      ClassStep('+', 'A few', 0.5, detail: '< 1 %'),
      ClassStep('1', 'A trace', 3, detail: '1–5 %'),
      ClassStep('2', 'A little', 15, detail: '5–25 %'),
      ClassStep('3', 'Some', 37.5, detail: '25–50 %'),
      ClassStep('4', 'Half or more', 62.5, detail: '50–75 %'),
      ClassStep('5', 'Most of it', 87.5, detail: '75–100 %'),
    ],
  ),
  'severity4': ClassScale(
    key: 'severity4',
    methodName: 'none / slight / moderate / severe',
    unit: 'class',
    classes: [
      ClassStep('0', 'None', 0),
      ClassStep('1', 'A little', 1, detail: 'slight'),
      ClassStep('2', 'Some', 2, detail: 'moderate'),
      ClassStep('3', 'A lot', 3, detail: 'severe'),
    ],
  ),
  'wind4': ClassScale(
    key: 'wind4',
    methodName: 'Beaufort 0–3',
    unit: 'class',
    classes: [
      ClassStep('0', 'Calm', 0),
      ClassStep('1', 'Leaves rustle', 1),
      ClassStep('2', 'Branches move', 2),
      ClassStep('3', 'Too windy', 3, detail: 'do not count'),
    ],
  ),
};

/// Zero in a Daubenmire frame is a legal answer — "none of this kind" —
/// and it counts toward the mean. Stored as code '0'.
const absentCode = '0';

/// A class answer's number for export and indicators: the scale's midpoint,
/// or 0 for the absent code.
double? classValue(String? scaleKey, Object? code) {
  if (code == null) return null;
  if ('$code' == absentCode) return 0;
  return scales[scaleKey]?.valueOf(code);
}
