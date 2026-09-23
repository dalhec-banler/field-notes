import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';
import '../services/property_locator.dart';

const kTenureLabels = {
  'owned': 'Owned',
  'leased': 'Leased',
  'public': 'Public land',
  'collection_site': 'Collection site',
  'other': 'Other',
};

/// "New place" dialog (D-003: multi-property from day one). Validates inside
/// the dialog — CREATE stays disabled until there is a name — and returns the
/// inserted property, or null if cancelled.
Future<Property?> showNewPlaceDialog(
  BuildContext context,
  FieldNotesDb db,
) async {
  final nameController = TextEditingController();
  var tenure = 'owned';
  final created = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: const Text('NEW PLACE'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'NAME',
                hintText: 'Home place, North pasture…',
              ),
              onChanged: (_) => setDialog(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: tenure,
              decoration: const InputDecoration(labelText: 'LAND TENURE'),
              items: [
                for (final e in kTenureLabels.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setDialog(() => tenure = v ?? 'owned'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: nameController.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, true),
            child: const Text('CREATE'),
          ),
        ],
      ),
    ),
  );
  final name = nameController.text.trim();
  nameController.dispose();
  if (created != true || name.isEmpty) return null;
  final now = nowUtcIso();
  final id = newId();
  await db
      .into(db.properties)
      .insert(
        PropertiesCompanion.insert(
          id: id,
          name: name,
          landTenure: Value(tenure),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ),
      );
  // Standing on the place when you name it is the common case: take the
  // phone's last cached fix if there is one. Never waits for GPS.
  await PropertyLocator(db).noteLastKnownFix(id);
  return (db.select(db.properties)..where((p) => p.id.equals(id))).getSingle();
}
