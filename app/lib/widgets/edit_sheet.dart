import 'package:flutter/material.dart';

import '../db/database.dart';
import '../theme/tokens.dart';
import 'confirm.dart';
import 'press.dart';
import 'species_field.dart';

/// One editor for every entry in the app (Austin, 2026-09-07: "every
/// entry, no matter what it is or where it is in the app, can be
/// edited" — a batch started ten days ago was stamped with today and
/// couldn't be changed). A screen describes its fields; the sheet draws
/// them, hands back what was typed, and offers DELETE when the screen
/// allows it. Nothing here writes: the caller owns its table.
sealed class EditField {
  const EditField(this.key, this.label);
  final String key;
  final String label;
}

class TextEdit extends EditField {
  const TextEdit(
    super.key,
    super.label, {
    this.initial,
    this.lines = 1,
    this.hint,
    this.required = false,
  });
  final String? initial;
  final int lines;
  final String? hint;

  /// SAVE stays off until this has text.
  final bool required;
}

class NumberEdit extends EditField {
  const NumberEdit(
    super.key,
    super.label, {
    this.initial,
    this.decimal = false,
    this.signed = false,
    this.hint,
  });
  final num? initial;
  final bool decimal, signed;
  final String? hint;
}

/// A calendar day. Give it a day ('2026-08-28') or a full timestamp — the
/// day is what's shown and edited; [withDay] keeps a timestamp's time.
class DateEdit extends EditField {
  const DateEdit(super.key, super.label, {this.initial});
  final String? initial;
}

class ChoiceEdit extends EditField {
  const ChoiceEdit(
    super.key,
    super.label, {
    required this.options,
    this.initial,
    this.allowNone = false,
  });

  /// (stored value, what the person reads).
  final List<(String, String)> options;
  final String? initial;
  final bool allowNone;
}

class SpeciesEdit extends EditField {
  const SpeciesEdit(super.key, super.label, {this.initial});
  final TaxaData? initial;
}

class ToggleEdit extends EditField {
  const ToggleEdit(super.key, super.label, {this.initial = false});
  final bool initial;
}

class EditResult {
  const EditResult(this.values, {this.deleted = false});
  final Map<String, Object?> values;
  final bool deleted;

  /// Trimmed text, null when empty.
  String? text(String key) => values[key] as String?;
  int? integer(String key) => (values[key] as num?)?.toInt();
  double? number(String key) => (values[key] as num?)?.toDouble();
  bool flag(String key) => values[key] == true;
  TaxaData? taxon(String key) => values[key] as TaxaData?;

  /// A DateEdit's day, or null.
  String? day(String key) => values[key] as String?;
}

/// [iso] with its day replaced by [day] ('yyyy-mm-dd'); a bare day gets a
/// midday UTC time so it sorts inside the day it names.
String withDay(String? iso, String day) {
  if (iso == null || iso.length <= 10) return '${day}T12:00:00Z';
  return '$day${iso.substring(10)}';
}

Future<EditResult?> showEditSheet(
  BuildContext context, {
  required String title,
  required List<EditField> fields,
  FieldNotesDb? db,
  String saveLabel = 'SAVE',

  /// Offer DELETE, confirmed with this title and body. The caller then
  /// soft-deletes (deleted_at) — nothing is erased from disk.
  String? deleteTitle,
  String? deleteBody,
}) async {
  assert(
    fields.whereType<SpeciesEdit>().isEmpty || db != null,
    'SpeciesEdit needs the database',
  );
  final controllers = <String, TextEditingController>{};
  final values = <String, Object?>{};
  for (final f in fields) {
    switch (f) {
      case TextEdit():
        controllers[f.key] = TextEditingController(text: f.initial ?? '');
      case NumberEdit():
        controllers[f.key] = TextEditingController(
          text: f.initial == null ? '' : _num(f.initial!),
        );
      case DateEdit():
        values[f.key] = f.initial == null || f.initial!.length < 10
            ? null
            : f.initial!.substring(0, 10);
      case ChoiceEdit():
        values[f.key] = f.initial;
      case SpeciesEdit():
        values[f.key] = f.initial;
      case ToggleEdit():
        values[f.key] = f.initial;
    }
  }

  bool complete() => fields.whereType<TextEdit>().every(
    (f) => !f.required || controllers[f.key]!.text.trim().isNotEmpty,
  );

  Map<String, Object?> collect() {
    final out = Map<String, Object?>.from(values);
    for (final f in fields) {
      switch (f) {
        case TextEdit():
          final t = controllers[f.key]!.text.trim();
          out[f.key] = t.isEmpty ? null : t;
        case NumberEdit():
          final t = controllers[f.key]!.text.trim();
          out[f.key] = f.decimal ? double.tryParse(t) : int.tryParse(t);
        default:
          break;
      }
    }
    return out;
  }

  final result = await showModalBottomSheet<EditResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Press.paper,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.all(Metrics.gutter),
          children: [
            MonoLabel(title, size: 10, spacing: 2),
            SizedBox(height: 12),
            for (final f in fields) ...[
              switch (f) {
                TextEdit() => TextField(
                  controller: controllers[f.key],
                  maxLines: f.lines,
                  minLines: f.lines > 1 ? 2 : 1,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: f.required ? (_) => setSheet(() {}) : null,
                  decoration: InputDecoration(
                    labelText: f.label,
                    helperText: f.hint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                NumberEdit() => TextField(
                  controller: controllers[f.key],
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: f.decimal,
                    signed: f.signed,
                  ),
                  decoration: InputDecoration(
                    labelText: f.label,
                    helperText: f.hint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                DateEdit() => DateRow(
                  label: f.label,
                  day: values[f.key] as String?,
                  onPick: (d) => setSheet(() => values[f.key] = d),
                ),
                ChoiceEdit() => DropdownButtonFormField<String>(
                  initialValue: values[f.key] as String?,
                  decoration: InputDecoration(
                    labelText: f.label,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    if (f.allowNone)
                      const DropdownMenuItem(value: null, child: Text('—')),
                    for (final (v, l) in f.options)
                      DropdownMenuItem(value: v, child: Text(l)),
                  ],
                  onChanged: (v) => values[f.key] = v,
                ),
                SpeciesEdit() => SpeciesField(
                  db: db!,
                  label: f.label,
                  initial: f.initial,
                  onSelected: (t) => values[f.key] = t,
                ),
                ToggleEdit() => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(f.label),
                  value: values[f.key] == true,
                  onChanged: (v) => setSheet(() => values[f.key] = v),
                ),
              },
              SizedBox(height: 12),
            ],
            SizedBox(height: 4),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: complete()
                    ? () => Navigator.pop(ctx, EditResult(collect()))
                    : null,
                child: Text(saveLabel),
              ),
            ),
            if (deleteTitle != null) ...[
              SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: TextButton(
                  style: TextButton.styleFrom(foregroundColor: Press.oxblood),
                  onPressed: () async {
                    final sure = await confirmDialog(
                      ctx,
                      title: deleteTitle,
                      body:
                          deleteBody ??
                          'It leaves every list and map. Nothing is erased '
                              'from disk.',
                      confirmLabel: 'DELETE',
                    );
                    if (sure && ctx.mounted) {
                      Navigator.pop(ctx, const EditResult({}, deleted: true));
                    }
                  },
                  child: const Text('DELETE'),
                ),
              ),
            ],
            SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
  for (final c in controllers.values) {
    c.dispose();
  }
  return result;
}

String _num(num v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

/// A day picker row, the shape every editor uses.
class DateRow extends StatelessWidget {
  const DateRow({super.key, required this.label, required this.day, required this.onPick});
  final String label;
  final String? day;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final initial = DateTime.tryParse(day ?? '') ?? DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: DateTime(1990),
          lastDate: DateTime(2100),
        );
        if (picked != null) onPick(picked.toIso8601String().substring(0, 10));
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.event),
        ),
        child: Text(
          day ?? 'Pick a day',
          style: TextStyle(
            fontFamily: Type.mono,
            fontSize: 14,
            color: day == null ? Press.inkSoft : Press.ink,
          ),
        ),
      ),
    );
  }
}
