import 'package:flutter/material.dart';

import 'db/database.dart';
import 'db/seed.dart';
import 'map/map_screen.dart';

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

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.db});

  final FieldNotesDb db;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Field Notes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Map',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MapScreen()),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<Property>>(
        stream: db.select(db.properties).watch(),
        builder: (context, snapshot) {
          final properties = snapshot.data ?? const [];
          if (properties.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No properties yet.\nAdd your first property to start recording.',
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
                title: Text(p.name),
                subtitle: Text(p.landTenure),
              );
            },
          );
        },
      ),
    );
  }
}
