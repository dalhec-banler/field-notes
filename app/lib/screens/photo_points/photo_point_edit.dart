import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../widgets/edit_sheet.dart';

/// Edit a station's fixed facts. Position stays where the first frame
/// fixed it; the rest — name, subject, cadence, focal length, bearing —
/// is the person's to correct. Returns true when the point was deleted.
Future<bool?> editPhotoPoint(
  BuildContext context,
  FieldNotesDb db,
  PhotoPoint p,
) async {
  final r = await showEditSheet(
    context,
    title: 'Edit photo point',
    fields: [
      TextEdit('name', 'Name', initial: p.name, required: true),
      TextEdit('subject', 'Subject (looking at…)', initial: p.subject),
      NumberEdit('cadence', 'Repeat every N days', initial: p.cadenceDays),
      NumberEdit(
        'bearing',
        'Bearing (°)',
        initial: p.bearingDeg,
        decimal: true,
      ),
      NumberEdit(
        'focal',
        'Focal length (mm)',
        initial: p.focalLengthMm,
        decimal: true,
        hint: '26 = phone main',
      ),
      NumberEdit(
        'extent',
        'View out to (m)',
        initial: p.viewExtentM,
        decimal: true,
      ),
    ],
    deleteTitle: 'DELETE THIS PHOTO POINT?',
    deleteBody:
        'Its visits and frames stay on disk; the station leaves '
        'the map and the list.',
  );
  if (r == null) return null;
  final now = nowUtcIso();
  final q = db.update(db.photoPoints)..where((x) => x.id.equals(p.id));
  if (r.deleted) {
    await q.write(
      PhotoPointsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    return true;
  }
  await q.write(
    PhotoPointsCompanion(
      name: Value(r.text('name') ?? p.name),
      subject: Value(r.text('subject')),
      cadenceDays: Value(r.integer('cadence')),
      bearingDeg: Value(r.number('bearing') ?? p.bearingDeg),
      focalLengthMm: Value(r.number('focal')),
      viewExtentM: Value(r.number('extent')),
      updatedAt: Value(now),
    ),
  );
  return false;
}

/// A visit's day and notes. Returns true when the visit was deleted.
Future<bool?> editPhotoPointVisit(
  BuildContext context,
  FieldNotesDb db,
  PhotoPointVisit v,
) async {
  final r = await showEditSheet(
    context,
    title: 'Edit visit',
    fields: [
      DateEdit('on', 'Visited on', initial: v.visitedAt),
      TextEdit('notes', 'Notes', initial: v.notes, lines: 2),
    ],
    deleteTitle: 'DELETE THIS VISIT?',
    deleteBody: 'The frame leaves the history. Nothing is erased from disk.',
  );
  if (r == null) return null;
  final now = nowUtcIso();
  final q = db.update(db.photoPointVisits)..where((x) => x.id.equals(v.id));
  if (r.deleted) {
    await q.write(
      PhotoPointVisitsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    return true;
  }
  await q.write(
    PhotoPointVisitsCompanion(
      visitedAt: Value(withDay(v.visitedAt, r.day('on') ?? v.visitedAt)),
      notes: Value(r.text('notes')),
      updatedAt: Value(now),
    ),
  );
  return false;
}
