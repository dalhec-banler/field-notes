import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../db/database.dart';
import '../main.dart' show locationHub;

/// Features & infrastructure (spec §7.9): map-worthy things with condition
/// history — springs, guzzlers, headcuts, gates.
class FeaturesScreen extends StatefulWidget {
  const FeaturesScreen({
    super.key,
    required this.db,
    required this.property,
    this.embedded = false,
  });

  final FieldNotesDb db;
  final Property property;
  final bool embedded;

  @override
  State<FeaturesScreen> createState() => _FeaturesScreenState();
}

class _FeaturesScreenState extends State<FeaturesScreen> {
  List<FeatureType> _types = const [];

  /// True from the moment the sheet closes until the row is written — the
  /// FAB is off meanwhile so a second tap can't make a duplicate (audit M19).
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _loadTypes();
  }

  Future<void> _loadTypes() async {
    final types = await (widget.db.select(
      widget.db.featureTypes,
    )..orderBy([(t) => OrderingTerm.asc(t.label)])).get();
    if (mounted) setState(() => _types = types);
  }

  String _typeLabel(String id) =>
      _types.where((t) => t.id == id).firstOrNull?.label ?? 'Feature';

  Future<void> _addFeature() async {
    if (_adding) return;
    FeatureType? type;
    final nameController = TextEditingController();
    final notesController = TextEditingController();
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(
                'New feature',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<FeatureType>(
                initialValue: type,
                decoration: const InputDecoration(
                  labelText: 'Type',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final t in _types)
                    DropdownMenuItem(value: t, child: Text(t.label)),
                ],
                onChanged: (v) => setSheet(() => type = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name (e.g. House spring)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notesController,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                type == null
                    ? 'Pick a type to continue. Your current GPS position '
                          'is used for the location.'
                    : 'Location: your current GPS position is used.',
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 56,
                child: FilledButton(
                  // Validated inside the sheet (audit M12): no type, no save.
                  onPressed: type == null
                      ? null
                      : () => Navigator.pop(context, true),
                  child: const Text('Add feature'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final chosen = type;
    if (created != true || chosen == null || !mounted) return;

    setState(() => _adding = true);
    try {
      // Hub fix first (instant); otherwise a short wait, then the centroid.
      double? lat;
      double? lng;
      final fresh = locationHub.fresh();
      if (fresh != null) {
        lat = fresh.latitude;
        lng = fresh.longitude;
      } else {
        try {
          if (await locationHub.ensurePermission()) {
            final fix = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.best,
                timeLimit: Duration(seconds: 5),
              ),
            );
            lat = fix.latitude;
            lng = fix.longitude;
          }
        } catch (_) {}
        lat ??= widget.property.centroidLat;
        lng ??= widget.property.centroidLng;
      }

      final now = nowUtcIso();
      await widget.db
          .into(widget.db.features)
          .insert(
            FeaturesCompanion.insert(
              id: newId(),
              propertyId: widget.property.id,
              featureTypeId: chosen.id,
              name: Value(
                nameController.text.trim().isEmpty
                    ? null
                    : nameController.text.trim(),
              ),
              geojson: jsonEncode({
                'type': 'Point',
                'coordinates': [lng ?? 0, lat ?? 0],
              }),
              lat: Value(lat),
              lng: Value(lng),
              currentCondition: const Value('unknown'),
              notes: Value(
                notesController.text.trim().isEmpty
                    ? null
                    : notesController.text.trim(),
              ),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Couldn\'t save the feature: $e')));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _logCondition(Feature feature) async {
    var condition = feature.currentCondition ?? 'good';
    final actionController = TextEditingController();
    final notesController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(
            'Condition — ${feature.name ?? _typeLabel(feature.featureTypeId)}',
          ),
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Log'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final now = nowUtcIso();
    await widget.db
        .into(widget.db.featureConditionLogs)
        .insert(
          FeatureConditionLogsCompanion.insert(
            id: newId(),
            propertyId: feature.propertyId,
            featureId: feature.id,
            observedAt: now,
            condition: condition,
            actionTaken: Value(
              actionController.text.trim().isEmpty
                  ? null
                  : actionController.text.trim(),
            ),
            notes: Value(
              notesController.text.trim().isEmpty
                  ? null
                  : notesController.text.trim(),
            ),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await (widget.db.update(
      widget.db.features,
    )..where((f) => f.id.equals(feature.id))).write(
      FeaturesCompanion(
        currentCondition: Value(condition),
        updatedAt: Value(now),
      ),
    );
  }

  Color _conditionColor(String? c) => switch (c) {
    'good' => Colors.green.shade700,
    'fair' => Colors.orange.shade700,
    'poor' => Colors.deepOrange.shade700,
    'critical' => Colors.red.shade700,
    _ => Colors.grey,
  };

  @override
  Widget build(BuildContext context) {
    final query = (widget.db.select(widget.db.features)
      ..where((f) => f.propertyId.equals(widget.property.id))
      ..where((f) => f.deletedAt.isNull())
      ..orderBy([(f) => OrderingTerm.asc(f.name)]));
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Features')),
      floatingActionButton: FloatingActionButton.extended(
        icon: _adding
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_location_alt_outlined),
        label: Text(_adding ? 'Finding position…' : 'Add feature'),
        onPressed: _adding ? null : _addFeature,
      ),
      body: StreamBuilder<List<Feature>>(
        stream: query.watch(),
        builder: (context, snapshot) {
          final features = snapshot.data ?? const [];
          if (features.isEmpty) {
            return const Center(
              child: Text(
                'No features yet.\nSprings, guzzlers, headcuts, gates…',
                textAlign: TextAlign.center,
              ),
            );
          }
          return ListView.builder(
            itemCount: features.length,
            itemBuilder: (context, i) {
              final f = features[i];
              return ListTile(
                minTileHeight: 64,
                leading: CircleAvatar(
                  backgroundColor: _conditionColor(f.currentCondition)
                      .withAlpha(40),
                  child: Icon(
                    Icons.place_outlined,
                    color: _conditionColor(f.currentCondition),
                  ),
                ),
                title: Text(f.name ?? _typeLabel(f.featureTypeId)),
                subtitle: Text(
                  [
                    _typeLabel(f.featureTypeId),
                    f.currentCondition ?? 'unknown',
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.fact_check_outlined),
                onTap: () => _logCondition(f),
              );
            },
          );
        },
      ),
    );
  }
}
