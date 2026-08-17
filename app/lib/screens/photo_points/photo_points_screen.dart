import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../db/database.dart';
import 'ghost_capture_screen.dart';

/// Photo points (spec §7.8): due list; capture with ghost overlay.
class PhotoPointsScreen extends StatelessWidget {
  const PhotoPointsScreen(
      {super.key,
      required this.db,
      required this.property,
      this.embedded = false});

  final FieldNotesDb db;
  final Property property;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final query = (db.select(db.photoPoints)
      ..where((p) => p.propertyId.equals(property.id))
      ..where((p) => p.deletedAt.isNull())
      ..orderBy([(p) => OrderingTerm.asc(p.name)]));
    return Scaffold(
      appBar: embedded ? null : AppBar(title: const Text('Photo points')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_a_photo_outlined),
        label: const Text('New photo point'),
        onPressed: () => _create(context),
      ),
      body: StreamBuilder<List<PhotoPoint>>(
        stream: query.watch(),
        builder: (context, snapshot) {
          final points = snapshot.data ?? const [];
          if (points.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No photo points yet.\n\nA photo point is a fixed spot and '
                  'bearing you re-photograph over months and years. The ghost '
                  'overlay lines each new shot up with the first one.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final today = nowUtcIso().substring(0, 10);
          return ListView.builder(
            itemCount: points.length,
            itemBuilder: (context, i) {
              final p = points[i];
              final due = p.nextDueOn != null &&
                  p.nextDueOn!.compareTo(today) <= 0;
              return ListTile(
                minTileHeight: 64,
                leading: CircleAvatar(
                  backgroundColor:
                      due ? Colors.orange.shade100 : null,
                  child: Icon(Icons.photo_camera_outlined,
                      color: due ? Colors.orange.shade800 : null),
                ),
                title: Text(p.name),
                subtitle: Text([
                  if (p.subject != null) p.subject!,
                  '${p.bearingDeg.toStringAsFixed(0)}°',
                  if (p.nextDueOn != null)
                    due ? 'DUE' : 'next ${p.nextDueOn}',
                ].join(' · ')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => GhostCaptureScreen(db: db, point: p),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final nameController = TextEditingController();
    final subjectController = TextEditingController();
    final cadenceController = TextEditingController(text: '30');
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New photo point'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: subjectController,
              decoration: const InputDecoration(
                  labelText: 'Subject (looking at…)'),
            ),
            TextField(
              controller: cadenceController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Repeat every N days'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Stand at the spot, aim at the subject, and save — position '
              'and bearing are captured with the first photo.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (created != true || nameController.text.trim().isEmpty) return;

    double lat = property.centroidLat ?? 0;
    double lng = property.centroidLng ?? 0;
    try {
      final fix = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              timeLimit: Duration(seconds: 10)));
      lat = fix.latitude;
      lng = fix.longitude;
    } catch (_) {}

    final now = nowUtcIso();
    final cadence = int.tryParse(cadenceController.text.trim());
    await db.into(db.photoPoints).insert(PhotoPointsCompanion.insert(
          id: newId(),
          propertyId: property.id,
          name: nameController.text.trim(),
          lat: lat,
          lng: lng,
          bearingDeg: 0, // set with the first captured frame
          subject: Value(subjectController.text.trim().isEmpty
              ? null
              : subjectController.text.trim()),
          cadenceDays: Value(cadence),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
  }
}
