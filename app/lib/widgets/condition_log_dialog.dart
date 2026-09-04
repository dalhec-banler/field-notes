import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';

/// One condition entry for a record (the merged feature timeline,
/// 2026-09-04): condition, action taken, notes. Returns true when a row
/// was written.
Future<bool> showConditionLogDialog(
  BuildContext context, {
  required FieldNotesDb db,
  required Observation obs,
}) async {
  var condition = 'good';
  final actionController = TextEditingController();
  final notesController = TextEditingController();
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: const Text('LOG CONDITION'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: condition,
              decoration: const InputDecoration(labelText: 'Condition'),
              items: const [
                DropdownMenuItem(value: 'good', child: Text('Good')),
                DropdownMenuItem(value: 'fair', child: Text('Fair')),
                DropdownMenuItem(value: 'poor', child: Text('Poor')),
                DropdownMenuItem(value: 'critical', child: Text('Critical')),
                DropdownMenuItem(value: 'unknown', child: Text('Unknown')),
              ],
              onChanged: (v) => setDialog(() => condition = v ?? condition),
            ),
            TextField(
              controller: actionController,
              decoration: const InputDecoration(labelText: 'Action taken'),
            ),
            TextField(
              controller: notesController,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('LOG'),
          ),
        ],
      ),
    ),
  );
  final action = actionController.text.trim();
  final notes = notesController.text.trim();
  actionController.dispose();
  notesController.dispose();
  if (saved != true) return false;
  final now = nowUtcIso();
  await db
      .into(db.conditionLogs)
      .insert(
        ConditionLogsCompanion.insert(
          id: newId(),
          propertyId: obs.propertyId,
          observationId: obs.id,
          observedAt: now,
          condition: condition,
          actionTaken: Value(action.isEmpty ? null : action),
          notes: Value(notes.isEmpty ? null : notes),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ),
      );
  return true;
}
