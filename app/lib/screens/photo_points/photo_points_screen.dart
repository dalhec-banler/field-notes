import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../db/database.dart';
import '../../main.dart' show locationHub;
import 'ghost_capture_screen.dart';
import 'photo_point_history_screen.dart';

/// Photo points (spec §7.8): due list; capture with ghost overlay.
class PhotoPointsScreen extends StatefulWidget {
  const PhotoPointsScreen({
    super.key,
    required this.db,
    required this.property,
    this.embedded = false,
  });

  final FieldNotesDb db;
  final Property property;
  final bool embedded;

  @override
  State<PhotoPointsScreen> createState() => _PhotoPointsScreenState();
}

class _PhotoPointsScreenState extends State<PhotoPointsScreen> {
  FieldNotesDb get db => widget.db;
  Property get property => widget.property;

  /// True from the moment the dialog closes until the row is written — the
  /// FAB is off meanwhile so a second tap can't make a duplicate (audit M19).
  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    final query = (db.select(db.photoPoints)
      ..where((p) => p.propertyId.equals(property.id))
      ..where((p) => p.deletedAt.isNull())
      ..orderBy([(p) => OrderingTerm.asc(p.name)]));
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(title: const Text('Photo points')),
      floatingActionButton: FloatingActionButton.extended(
        icon: _creating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_a_photo_outlined),
        label: Text(_creating ? 'Finding position…' : 'New photo point'),
        onPressed: _creating ? null : _create,
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
          bool isDue(PhotoPoint p) =>
              p.nextDueOn != null && p.nextDueOn!.compareTo(today) <= 0;
          // Due list first (spec §7.8), then the rest by name.
          final sorted = [...points]
            ..sort((a, b) {
              final d = (isDue(b) ? 1 : 0) - (isDue(a) ? 1 : 0);
              return d != 0 ? d : a.name.compareTo(b.name);
            });
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 140),
            itemCount: sorted.length,
            itemBuilder: (context, i) {
              final p = sorted[i];
              final due = isDue(p);
              return ListTile(
                minTileHeight: 64,
                leading: CircleAvatar(
                  backgroundColor: due ? Colors.orange.shade100 : null,
                  child: Icon(
                    Icons.photo_camera_outlined,
                    color: due ? Colors.orange.shade800 : null,
                  ),
                ),
                title: Text(p.name),
                subtitle: Text(
                  [
                    if (p.subject != null) p.subject!,
                    '${p.bearingDeg.toStringAsFixed(0)}°',
                    if (p.nextDueOn != null)
                      due ? 'DUE' : 'next ${p.nextDueOn}',
                  ].join(' · '),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.photo_camera_outlined),
                  tooltip: 'Capture a visit',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => GhostCaptureScreen(db: db, point: p),
                    ),
                  ),
                ),
                // Row → history (every frame, scrubbable); camera → capture.
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PhotoPointHistoryScreen(db: db, point: p),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _create() async {
    if (_creating) return;
    final nameController = TextEditingController();
    final subjectController = TextEditingController();
    final cadenceController = TextEditingController(text: '30');
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('New photo point'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                onChanged: (_) => setDialog(() {}),
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: subjectController,
                decoration: const InputDecoration(
                  labelText: 'Subject (looking at…)',
                ),
              ),
              TextField(
                controller: cadenceController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Repeat every N days',
                ),
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              // Validated inside the dialog (audit M12): a name is needed.
              onPressed: nameController.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    final name = nameController.text.trim();
    if (created != true || name.isEmpty || !mounted) return;

    setState(() => _creating = true);
    try {
      // Position is a placeholder until the first frame anchors the point
      // (D-007); a fresh fix is nicer than the centroid, but never wait long.
      double lat = property.centroidLat ?? 0;
      double lng = property.centroidLng ?? 0;
      final fix = locationHub.fresh();
      if (fix != null) {
        lat = fix.latitude;
        lng = fix.longitude;
      } else {
        try {
          if (await locationHub.ensurePermission()) {
            final f = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.best,
                timeLimit: Duration(seconds: 5),
              ),
            );
            lat = f.latitude;
            lng = f.longitude;
          }
        } catch (_) {}
      }

      final now = nowUtcIso();
      final cadence = int.tryParse(cadenceController.text.trim());
      await db
          .into(db.photoPoints)
          .insert(
            PhotoPointsCompanion.insert(
              id: newId(),
              propertyId: property.id,
              name: name,
              lat: lat,
              lng: lng,
              bearingDeg: 0, // set with the first captured frame
              subject: Value(
                subjectController.text.trim().isEmpty
                    ? null
                    : subjectController.text.trim(),
              ),
              cadenceDays: Value(cadence),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn\'t save the photo point: $e')),
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }
}
