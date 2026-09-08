import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../theme/tokens.dart';
import 'press.dart';
import 'species_field.dart';
import 'edit_sheet.dart';

/// What the editor was asked to do when it closed.
enum EditOutcome { saved, movePin }

const kObservationTypes = [
  'general',
  'plant',
  'wildlife',
  'problem',
  'water',
  'soil',
  'phenology',
  'sign',
  'maintenance',
  'infrastructure',
];

const kConfidenceLabels = {
  'certain': 'Certain',
  'probable': 'Probably',
  'uncertain': 'Not sure',
};

/// Edit what a field ID most often gets wrong: the species, the kind of
/// record, how sure you were, the day, and the notes. Location is the
/// record's evidence and stays as captured — MOVE THE PIN is the one
/// exception and is handed back to the caller (it needs a map), never done
/// here. The day is editable (Austin, 2026-09-07: every entry, its date
/// included); the time of day rides along unchanged.
///
/// The same editor serves the phone (bottom sheet) and the desk (dialog,
/// D-024): one set of rules for what an edit may touch.
Future<EditOutcome?> showEditRecordSheet(
  BuildContext context, {
  required FieldNotesDb db,
  required Observation obs,
  TaxaData? taxon,
  bool allowMovePin = true,
}) async {
  final notes = TextEditingController(text: obs.notes ?? '');
  var type = obs.observationType;
  String? confidence = obs.taxonConfidence;
  if (confidence == 'unidentified') confidence = null;
  TaxaData? picked = taxon;
  var day = obs.observedAt.length >= 10
      ? obs.observedAt.substring(0, 10)
      : obs.observedAt;

  Widget body(BuildContext ctx, StateSetter setSheet) => ListView(
    shrinkWrap: true,
    padding: EdgeInsets.all(Metrics.gutter),
    children: [
      MonoLabel('Edit record', size: 10, spacing: 2),
      SizedBox(height: 12),
      SpeciesField(
        db: db,
        label: 'Species — common or Latin name',
        initial: picked,
        onSelected: (t) => setSheet(() {
          picked = t;
          if (t == null) confidence = null;
          // Same default the capture flow writes: naming it from the
          // list counts as certain until you say otherwise.
          if (t != null && confidence == null) confidence = 'certain';
          if (t != null && type == 'general') type = 'plant';
        }),
      ),
      if (picked != null) ...[
        SizedBox(height: 12),
        MonoLabel('How sure?', size: 9, spacing: 1.8),
        SizedBox(height: 6),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (final e in kConfidenceLabels.entries)
              _Pill(
                e.value,
                confidence == e.key,
                () => setSheet(() => confidence = e.key),
              ),
          ],
        ),
      ],
      SizedBox(height: 14),
      MonoLabel('What kind of record', size: 9, spacing: 1.8),
      SizedBox(height: 6),
      Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          for (final t in kObservationTypes)
            _Pill(t.toUpperCase(), type == t, () => setSheet(() => type = t)),
        ],
      ),
      if (allowMovePin) ...[
        SizedBox(height: 14),
        // A wrong fix is forever until you can move it (batch 1).
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            icon: Icon(Icons.place_outlined, size: 18),
            label: Text('MOVE THE PIN'),
            onPressed: () => Navigator.pop(ctx, EditOutcome.movePin),
          ),
        ),
      ],
      SizedBox(height: 14),
      DateRow(
        label: 'Observed on',
        day: day,
        onPick: (d) => setSheet(() => day = d),
      ),
      SizedBox(height: 14),
      MonoLabel('Notes', size: 9, spacing: 1.8),
      SizedBox(height: 6),
      TextField(
        controller: notes,
        minLines: 3,
        maxLines: 8,
        textCapitalization: TextCapitalization.sentences,
        cursorColor: Press.oxblood,
        style: TextStyle(fontFamily: Type.serif, fontSize: 16, height: 1.5),
        decoration: InputDecoration(hintText: 'What did you see?'),
      ),
      SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx, EditOutcome.saved),
                child: Text('SAVE CHANGES'),
              ),
            ),
          ),
          SizedBox(width: 8),
          SizedBox(
            height: 52,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('CANCEL'),
            ),
          ),
        ],
      ),
    ],
  );

  final wide = MediaQuery.sizeOf(context).width >= 700;
  final EditOutcome? outcome;
  if (wide) {
    outcome = await showDialog<EditOutcome>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Press.paper,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Press.borderInk, width: 1.5),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 560),
          child: StatefulBuilder(
            builder: (ctx, setSheet) =>
                Padding(padding: EdgeInsets.all(8), child: body(ctx, setSheet)),
          ),
        ),
      ),
    );
  } else {
    outcome = await showModalBottomSheet<EditOutcome>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Press.paper,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            // Keep the keyboard clear, and stay out from under the clock.
            top: MediaQuery.of(ctx).padding.top + 8,
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SafeArea(top: false, child: body(ctx, setSheet)),
        ),
      ),
    );
  }

  final text = notes.text.trim();
  notes.dispose();
  if (outcome != EditOutcome.saved) return outcome;
  await (db.update(db.observations)..where((o) => o.id.equals(obs.id))).write(
    ObservationsCompanion(
      taxonId: Value(picked?.id),
      taxonConfidence: Value(picked == null ? 'unidentified' : confidence),
      observationType: Value(type),
      observedAt: Value(withDay(obs.observedAt, day)),
      notes: Value(text.isEmpty ? null : text),
      updatedAt: Value(nowUtcIso()),
    ),
  );
  return EditOutcome.saved;
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, this.on, this.onTap);
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56, // glove target (spec §7)
        padding: EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: on ? Press.ink : null,
          border: Border.all(color: Press.borderInk, width: 1),
          borderRadius: BorderRadius.circular(999),
        ),
        // Center(widthFactor) keeps the pill hugging its label inside a Wrap.
        child: Center(
          widthFactor: 1,
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: Type.mono,
              fontSize: 9.5,
              letterSpacing: 1.4,
              color: on ? Press.paper : Press.ink,
            ),
          ),
        ),
      ),
    );
  }
}
