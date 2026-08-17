import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'backup/restore.dart';
import 'db/database.dart';
import 'db/seed.dart';
import 'export/exporter.dart';
import 'services/app_prefs.dart';
import 'services/env_context.dart';
import 'services/track_recorder.dart';
import 'shell/app_shell.dart';
import 'theme/theme.dart';
import 'theme/tokens.dart';
import 'widgets/press.dart';

/// App-wide track recorder: recording must survive navigation and screen
/// sleep (spec §4.13).
late final TrackRecorder trackRecorder;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Apply a staged restore before the database opens (spec §11.9).
  RestorePipeline? pendingRestore;
  try {
    final docs = await getApplicationDocumentsDirectory();
    final pipeline = RestorePipeline(docs);
    if (pipeline.hasStagedRestore) {
      pipeline.applyStagedDb(p.join(docs.path, 'field_notes.sqlite'));
      pendingRestore = pipeline;
    }
  } catch (_) {
    // A failed restore attempt must never brick startup.
  }
  final db = FieldNotesDb();
  if (pendingRestore != null) {
    // Media repoints in the background; the DB is already live.
    pendingRestore.remapRestoredMedia(db);
  }
  // First-run species library; never blocks the UI (spec: offline-first, no
  // startup gates).
  seedTaxaIfEmpty(db);
  seedFeatureTypesIfEmpty(db);
  // Retry pass for env contexts created offline (spec §4.11).
  EnvContextService(db).backfillStale();
  trackRecorder = TrackRecorder(db);
  final prefs = await AppPrefs.load();
  runApp(FieldNotesApp(db: db, prefs: prefs));
}

class FieldNotesApp extends StatelessWidget {
  const FieldNotesApp({super.key, required this.db, required this.prefs});

  final FieldNotesDb db;
  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Field Station',
      theme: fieldStationTheme(),
      home: RootScreen(db: db, prefs: prefs),
    );
  }
}

/// Boots into the five-tab shell on the active property; falls back to
/// first-run place creation when the database has no properties.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key, required this.db, required this.prefs});

  final FieldNotesDb db;
  final AppPrefs prefs;

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  Property? _active;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _resolveActive();
  }

  Future<void> _resolveActive() async {
    final properties = await (widget.db.select(widget.db.properties)
          ..where((x) => x.deletedAt.isNull())
          ..orderBy([(x) => OrderingTerm.asc(x.name)]))
        .get();
    Property? active;
    final savedId = widget.prefs.activePropertyId;
    if (savedId != null) {
      active = properties.where((x) => x.id == savedId).firstOrNull;
    }
    active ??= properties.firstOrNull;
    if (mounted) {
      setState(() {
        _active = active;
        _loaded = true;
      });
    }
  }

  void _switchTo(Property property) {
    widget.prefs.activePropertyId = property.id;
    setState(() => _active = property);
  }

  Future<void> _createFirstPlace() async {
    final nameController = TextEditingController();
    var tenure = 'owned';
    const tenureLabels = {
      'owned': 'Owned',
      'leased': 'Leased',
      'public': 'Public land',
      'collection_site': 'Collection site',
      'other': 'Other',
    };
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
                decoration: const InputDecoration(labelText: 'NAME'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: tenure,
                decoration: const InputDecoration(labelText: 'LAND TENURE'),
                items: [
                  for (final e in tenureLabels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setDialog(() => tenure = v ?? 'owned'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('CANCEL')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('CREATE')),
          ],
        ),
      ),
    );
    if (created != true || nameController.text.trim().isEmpty) return;
    final now = nowUtcIso();
    final id = newId();
    await widget.db.into(widget.db.properties).insert(
          PropertiesCompanion.insert(
            id: id,
            name: nameController.text.trim(),
            landTenure: Value(tenure),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    widget.prefs.activePropertyId = id;
    _resolveActive();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: SizedBox.shrink());
    }
    final active = _active;
    if (active == null) {
      // First run — no places yet.
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                const Kicker('Local-first field journal'),
                const SizedBox(height: 8),
                const Text(
                  'FIELD\nSTATION',
                  style: TextStyle(
                    fontFamily: Type.slab,
                    fontWeight: FontWeight.w900,
                    fontSize: 52,
                    height: 0.9,
                    color: Press.ink,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'The record lives on this phone. It works with the radio '
                  'off. Add the land you walk — owned, leased, public, or a '
                  'collection site.',
                  style: TextStyle(
                      fontFamily: Type.serif, fontSize: 16.5, height: 1.5),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  height: 58,
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _createFirstPlace,
                    child: const Text('ADD A PLACE'),
                  ),
                ),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ),
      );
    }
    return AppShell(
      db: widget.db,
      prefs: widget.prefs,
      property: active,
      onSwitchProperty: _switchTo,
    );
  }
}

/// Full export → zip → share sheet (spec §6). Shared by Settings.
Future<void> exportAndShare(
    BuildContext context, FieldNotesDb db, Property property) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('WRITING EXPORT…')));
  try {
    final docs = await getApplicationDocumentsDirectory();
    final dir = await Exporter(db)
        .exportProperty(property, Directory('${docs.path}/exports'));
    final zipPath = '${dir.path}.zip';
    final encoder = ZipFileEncoder()..create(zipPath);
    await encoder.addDirectory(dir);
    await encoder.close();
    messenger.hideCurrentSnackBar();
    await SharePlus.instance.share(ShareParams(
        files: [XFile(zipPath)],
        text: 'Field Station export — ${property.name}'));
  } catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('EXPORT FAILED: $e')));
  }
}
