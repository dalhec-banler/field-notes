import 'package:flutter/material.dart';

import 'db/database.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(FieldNotesApp(db: FieldNotesDb()));
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
      appBar: AppBar(title: const Text('Field Notes')),
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
