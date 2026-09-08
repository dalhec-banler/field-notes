import 'dart:convert';

import '../theme/tokens.dart';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../db/database.dart';
import '../main.dart' show locationHub;
import '../widgets/confirm.dart';
import '../widgets/edit_sheet.dart';

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
      var usedCentroid = false;
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
        if (lat == null) usedCentroid = true;
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
      // Flagged, never faked (the capture rule applies to features too).
      if (usedCentroid && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No GPS fix — placed at the property centre for now.',
            ),
          ),
        );
      }
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

  /// One home for condition ink (tokens.conditionColor); the stoplight
  /// Material shades were this screen's private dialect.
  Color _conditionColor(String? c) => conditionColor(c);

  Future<void> _editFeature(Feature f) async {
    final r = await showEditSheet(
      context,
      title: 'Edit feature',
      fields: [
        TextEdit('name', 'Name', initial: f.name),
        DateEdit('installed', 'Installed on', initial: f.installedOn),
        DateEdit('retired', 'Retired on', initial: f.retiredOn),
        TextEdit('notes', 'Notes', initial: f.notes, lines: 3),
      ],
    );
    if (r == null || r.deleted) return;
    await (widget.db.update(
      widget.db.features,
    )..where((x) => x.id.equals(f.id))).write(
      FeaturesCompanion(
        name: Value(r.text('name')),
        installedOn: Value(r.day('installed')),
        retiredOn: Value(r.day('retired')),
        notes: Value(r.text('notes')),
        updatedAt: Value(nowUtcIso()),
      ),
    );
  }

  Future<void> _editFeatureLog(Feature f, FeatureConditionLog l) async {
    final r = await showEditSheet(
      context,
      title: 'Edit condition',
      fields: [
        DateEdit('on', 'Observed on', initial: l.observedAt),
        ChoiceEdit(
          'condition',
          'Condition',
          options: const [
            ('good', 'Good'),
            ('fair', 'Fair'),
            ('poor', 'Poor'),
            ('critical', 'Critical'),
            ('unknown', 'Unknown'),
          ],
          initial: l.condition,
        ),
        TextEdit('action', 'Action taken', initial: l.actionTaken),
        TextEdit('notes', 'Notes', initial: l.notes, lines: 2),
      ],
      deleteTitle: 'DELETE THIS CONDITION ENTRY?',
    );
    if (r == null) return;
    final now = nowUtcIso();
    final q = widget.db.update(widget.db.featureConditionLogs)
      ..where((x) => x.id.equals(l.id));
    if (r.deleted) {
      await q.write(
        FeatureConditionLogsCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
        ),
      );
    } else {
      await q.write(
        FeatureConditionLogsCompanion(
          observedAt: Value(withDay(l.observedAt, r.day('on') ?? l.observedAt)),
          condition: Value(r.text('condition') ?? l.condition),
          actionTaken: Value(r.text('action')),
          notes: Value(r.text('notes')),
          updatedAt: Value(now),
        ),
      );
    }
    _openFeature(f);
  }

  Future<void> _openFeature(Feature f) async {
    final logs =
        await (widget.db.select(widget.db.featureConditionLogs)
              ..where((l) => l.featureId.equals(f.id))
              ..where((l) => l.deletedAt.isNull())
              ..orderBy([(l) => OrderingTerm.desc(l.observedAt)]))
            .get();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text(
              f.name ?? _typeLabel(f.featureTypeId),
              style: Theme.of(ctx).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '${_typeLabel(f.featureTypeId)} · '
              '${f.currentCondition ?? 'unknown'}',
            ),
            const SizedBox(height: 12),
            if (logs.isEmpty)
              const Text('No condition history yet — log the first look.')
            else
              for (final l in logs)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  onTap: () {
                    Navigator.pop(ctx);
                    _editFeatureLog(f, l);
                  },
                  leading: Icon(
                    Icons.circle,
                    size: 12,
                    color: conditionColor(l.condition),
                  ),
                  title: Text(
                    '${l.observedAt.substring(0, 10)} · ${l.condition}',
                  ),
                  subtitle: (l.actionTaken ?? l.notes) == null
                      ? null
                      : Text(
                          [
                            if (l.actionTaken != null) l.actionTaken!,
                            if (l.notes != null) l.notes!,
                          ].join(' · '),
                        ),
                ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _logCondition(f);
                },
                child: const Text('LOG CONDITION'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _editFeature(f);
                },
                child: const Text('EDIT FEATURE'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: OutlinedButton(
                onPressed: () async {
                  final sure = await confirmDialog(
                    ctx,
                    title: 'DELETE THIS FEATURE?',
                    body:
                        'It leaves the map and its condition history goes '
                        'quiet. Nothing is erased from disk.',
                    confirmLabel: 'DELETE',
                  );
                  if (!sure || !ctx.mounted) return;
                  final now = nowUtcIso();
                  await (widget.db.update(
                    widget.db.features,
                  )..where((x) => x.id.equals(f.id))).write(
                    FeaturesCompanion(
                      deletedAt: Value(now),
                      updatedAt: Value(now),
                    ),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('DELETE FEATURE'),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
            return Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'No features marked yet. Springs, guzzlers, headcuts, '
                  'gates — the built and the broken. Add one and its '
                  'condition history starts.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: Type.serif,
                    fontSize: 15,
                    height: 1.5,
                    color: Press.inkSoft,
                  ),
                ),
              ),
            );
          }
          return ListView.builder(
            padding: EdgeInsets.only(bottom: 140),
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
                trailing: IconButton(
                  tooltip: 'Log condition',
                  icon: const Icon(Icons.fact_check_outlined),
                  onPressed: () => _logCondition(f),
                ),
                // Tapping a row means LOOK at it, not fill in a form
                // (design audit P2): detail + history, with the log one
                // tap away.
                onTap: () => _openFeature(f),
              );
            },
          );
        },
      ),
    );
  }
}
