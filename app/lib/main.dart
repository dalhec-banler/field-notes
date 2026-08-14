import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import 'package:path_provider/path_provider.dart';

import 'db/database.dart';
import 'db/seed.dart';
import 'export/exporter.dart';
import 'map/map_screen.dart';
import 'screens/capture_screen.dart';
import 'screens/feed_screen.dart';
import 'screens/kml_import_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final db = FieldNotesDb();
  // First-run species library; never blocks the UI (spec: offline-first, no
  // startup gates).
  seedTaxaIfEmpty(db);
  runApp(FieldNotesApp(db: db));
}

class FieldNotesApp extends StatelessWidget {
  const FieldNotesApp({super.key, required this.db});

  final FieldNotesDb db;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Field Notes',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3E5F44),
          brightness: Brightness.light,
        ),
        // Spec §7: touch targets ≥ 56 dp — gloves.
        materialTapTargetSize: MaterialTapTargetSize.padded,
        visualDensity: VisualDensity.standard,
      ),
      home: HomeScreen(db: db),
    );
  }
}

const _tenureLabels = {
  'owned': 'Owned',
  'leased': 'Leased',
  'public': 'Public land',
  'collection_site': 'Collection site',
  'other': 'Other',
};

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.db});

  final FieldNotesDb db;

  Future<void> _addProperty(BuildContext context) async {
    final nameController = TextEditingController();
    var tenure = 'owned';
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('New place'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: tenure,
                decoration: const InputDecoration(labelText: 'Land tenure'),
                items: [
                  for (final e in _tenureLabels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => tenure = v ?? 'owned'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (created != true || nameController.text.trim().isEmpty) return;
    final now = nowUtcIso();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
          id: newId(),
          name: nameController.text.trim(),
          landTenure: Value(tenure),
          createdBy: 'local',
          createdAt: now,
          updatedAt: now,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final query = (db.select(db.properties)
      ..where((p) => p.deletedAt.isNull())
      ..orderBy([(p) => OrderingTerm.asc(p.name)]));
    return Scaffold(
      appBar: AppBar(title: const Text('Field Notes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addProperty(context),
        icon: const Icon(Icons.add),
        label: const Text('Add place'),
      ),
      body: StreamBuilder<List<Property>>(
        stream: query.watch(),
        builder: (context, snapshot) {
          final properties = snapshot.data ?? const [];
          if (properties.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No places yet.\nAdd your property, a lease, or a collection site to start recording.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18),
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: properties.length,
            itemBuilder: (context, i) {
              final p = properties[i];
              return ListTile(
                minTileHeight: 56,
                leading: CircleAvatar(
                  child: Icon(switch (p.landTenure) {
                    'public' => Icons.forest_outlined,
                    'collection_site' => Icons.content_cut,
                    'leased' => Icons.handshake_outlined,
                    _ => Icons.home_work_outlined,
                  }),
                ),
                title: Text(p.name),
                subtitle: Text(_tenureLabels[p.landTenure] ?? p.landTenure),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PropertyScreen(db: db, property: p),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class PropertyScreen extends StatelessWidget {
  const PropertyScreen({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  Widget build(BuildContext context) {
    final countQuery = (db.selectOnly(db.observations)
      ..addColumns([db.observations.id.count()])
      ..where(db.observations.propertyId.equals(property.id) &
          db.observations.deletedAt.isNull()));
    return Scaffold(
      appBar: AppBar(title: Text(property.name)),
      floatingActionButton: FloatingActionButton.large(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CaptureScreen(db: db, property: property),
          ),
        ),
        child: const Icon(Icons.add_a_photo, size: 36),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          StreamBuilder<int?>(
            stream: countQuery
                .watchSingle()
                .map((row) => row.read(db.observations.id.count())),
            builder: (context, snapshot) => ListTile(
              leading: const Icon(Icons.list_alt),
              title: const Text('Feed'),
              subtitle: Text('${snapshot.data ?? 0} records'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => FeedScreen(db: db, property: property),
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('Map'),
            onTap: () async {
              // Re-read: a KML import may have set the boundary after this
              // screen captured its property snapshot.
              final fresh = await (db.select(db.properties)
                    ..where((p) => p.id.equals(property.id)))
                  .getSingle();
              if (!context.mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MapScreen(db: db, property: fresh),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('Import KML/KMZ'),
            subtitle: const Text('Boundary, zones, pins'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => KmlImportScreen(db: db, property: property),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: const Text('Export all data'),
            subtitle: const Text('SQLite, CSV, GeoJSON, KML, photos'),
            onTap: () => _export(context),
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Exporting…')));
    try {
      // TODO(shared-storage): move to MediaStore/SAF so the folder shows over
      // USB (spec §6); app documents dir until then.
      final docs = await getApplicationDocumentsDirectory();
      final dir = await Exporter(db)
          .exportProperty(property, Directory('${docs.path}/exports'));
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('Exported to ${dir.path}')),
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }
}
