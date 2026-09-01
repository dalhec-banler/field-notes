import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../db/database.dart';

/// One plant's check-in (spec §4.8): status, height, vigor, browse. Shared
/// by the cohort screen and the plant dossier so a check-in means the same
/// thing wherever it's made. Returns true when a row was written.
Future<bool> showPlantCheckinDialog(
  BuildContext context, {
  required FieldNotesDb db,
  required Plant plant,
}) async {
  var status = plant.currentStatus;
  final heightController = TextEditingController();
  String? vigor;
  String? browse;
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: Text('Check in ${plant.tagCode ?? 'plant'}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: const [
                  DropdownMenuItem(value: 'alive', child: Text('Alive')),
                  DropdownMenuItem(value: 'dead', child: Text('Dead')),
                  DropdownMenuItem(value: 'missing', child: Text('Missing')),
                  DropdownMenuItem(value: 'dormant', child: Text('Dormant')),
                  DropdownMenuItem(value: 'browsed', child: Text('Browsed')),
                  DropdownMenuItem(
                    value: 'declining',
                    child: Text('Declining'),
                  ),
                  DropdownMenuItem(value: 'removed', child: Text('Removed')),
                ],
                onChanged: (v) => setDialog(() => status = v ?? status),
              ),
              TextField(
                controller: heightController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Height (cm)'),
              ),
              DropdownButtonFormField<String>(
                initialValue: vigor,
                decoration: const InputDecoration(labelText: 'Vigor'),
                items: const [
                  DropdownMenuItem(
                    value: 'excellent',
                    child: Text('Excellent'),
                  ),
                  DropdownMenuItem(value: 'good', child: Text('Good')),
                  DropdownMenuItem(value: 'fair', child: Text('Fair')),
                  DropdownMenuItem(value: 'poor', child: Text('Poor')),
                  DropdownMenuItem(value: 'dead', child: Text('Dead')),
                ],
                onChanged: (v) => setDialog(() => vigor = v),
              ),
              DropdownButtonFormField<String>(
                initialValue: browse,
                decoration: const InputDecoration(labelText: 'Browse pressure'),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('None')),
                  DropdownMenuItem(value: 'light', child: Text('Light')),
                  DropdownMenuItem(value: 'moderate', child: Text('Moderate')),
                  DropdownMenuItem(value: 'severe', child: Text('Severe')),
                ],
                onChanged: (v) => setDialog(() => browse = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  final height = double.tryParse(heightController.text.trim());
  heightController.dispose();
  if (saved != true) return false;
  final now = nowUtcIso();
  await db
      .into(db.plantCheckins)
      .insert(
        PlantCheckinsCompanion.insert(
          id: newId(),
          propertyId: plant.propertyId,
          plantId: Value(plant.id),
          checkedAt: now,
          status: status,
          heightCm: Value(height),
          vigor: Value(vigor),
          browsePressure: Value(browse),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ),
      );
  await (db.update(db.plants)..where((p) => p.id.equals(plant.id))).write(
    PlantsCompanion(
      currentStatus: Value(status),
      lastCheckedAt: Value(now),
      updatedAt: Value(now),
    ),
  );
  return true;
}
