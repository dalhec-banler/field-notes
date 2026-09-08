import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'backup/backup_service.dart';
import 'backup/restore.dart';
import 'db/database.dart';
import 'desktop/desktop_intake_screen.dart';
import 'desktop/desktop_shell.dart';
import 'db/seed.dart';
import 'export/exporter.dart';
import 'services/app_prefs.dart';
import 'services/desk.dart';
import 'services/env_context.dart';
import 'services/location_hub.dart';
import 'services/track_recorder.dart';
import 'map/imagery_sources.dart';
import 'shell/app_shell.dart';
import 'sync/oplog.dart';
import 'sync/sync_service.dart';

import 'theme/theme.dart';
import 'theme/tokens.dart';
import 'screens/onboarding_screen.dart';
import 'widgets/new_place_dialog.dart';
import 'widgets/press.dart';

/// This installation's change log, installed at launch; null only if
/// capture failed to start (sync then says so).
OpLog? opLog;

/// Single owner of the platform GPS stream; every screen listens here.
late final LocationHub locationHub;

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
    }
    // The DB swap consumes READY; APPLIED stays until every blob is placed,
    // so an interrupted remap resumes here without touching the DB again.
    if (pipeline.hasPendingMediaRemap) pendingRestore = pipeline;
  } catch (_) {
    // A failed restore attempt must never brick startup.
  }
  final db = FieldNotesDb();
  // M4a: capture every write from the first launch that has this build —
  // sync needs the history to exist before anyone flips it on.
  try {
    final docs = await getApplicationDocumentsDirectory();
    opLog = await OpLog.install(
      db,
      identityFile: File(p.join(docs.path, 'device_id.txt')),
    );
  } catch (_) {
    // Capture must never block startup; sync just starts later.
  }
  if (pendingRestore != null) {
    // Media repoints in the background; the DB is already live.
    pendingRestore.remapRestoredMedia(db).catchError((_) => 0);
  }
  // First-run species library; never blocks the UI (spec: offline-first, no
  // startup gates).
  seedTaxaIfEmpty(db);
  seedFeatureTypesIfEmpty(db);
  locationHub = LocationHub();
  trackRecorder = TrackRecorder(db, locationHub);
  // A track left open by a killed process is closed out from its raw points.
  // Startup never fails over it.
  trackRecorder.recoverOpenTracks().catchError((_) => 0);
  final prefs = await AppPrefs.load();
  // Retry pass for env contexts created offline (spec §4.11). Moved below
  // AppPrefs.load() deliberately: it must not run before we know whether the
  // user has switched it on, and it is off unless they have (D-022).
  EnvContextService(db).backfillStale(enabled: prefs.envContext);
  // Daily automatic backup + weekly verify, when due (spec §11.7–11.8).
  // Never gates startup.
  BackupService(db).maybeRunAutomatic(prefs).catchError((_) => null);
  // D-028: the sync carrier, same posture — when due, never a prompt.
  final log = opLog;
  if (log != null) {
    SyncService(db, prefs, log).maybeRunAutomatic().catchError((_) => null);
  }
  // The skin is process-wide state read during build (D-023); it must be
  // decided before the first frame and only ever changed with the rebuild
  // below, never mid-frame.
  skin = prefs.skinName == 'press' ? pressSkin : quietSkin;
  // Imagery source is the same kind of process-wide, decided-before-first-
  // frame state as the skin (D-023 pattern).
  activeImagery = imageryById(prefs.imagerySource);
  runApp(FieldNotesApp(db: db, prefs: prefs));
}

class FieldNotesApp extends StatelessWidget {
  FieldNotesApp({super.key, required this.db, required this.prefs});

  final FieldNotesDb db;
  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    // Prefs are a ChangeNotifier so an outdoor-mode flip re-themes live.
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        // Re-resolve the skin on every prefs change, and key the whole tree
        // by it: a skin swap must rebuild every widget, including the ones
        // that cached token values in `const`-free but long-lived state.
        skin = prefs.skinName == 'press' ? pressSkin : quietSkin;
        return MaterialApp(
          key: ValueKey('skin-${skin.name}'),
          title: 'Field Notes',
          theme: appTheme(),
          // Outdoor mode (spec §7): scale every text style up ~18 %. Layouts
          // are built to tolerate it; touch targets are already ≥ 56 dp.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            // Compose with the OS font-size setting; never override it.
            final scaled = prefs.outdoorMode
                ? TextScaler.linear(mq.textScaler.scale(1.0) * 1.18)
                : mq.textScaler;
            return MediaQuery(
              data: mq.copyWith(textScaler: scaled),
              child: child ?? SizedBox.shrink(),
            );
          },
          home: RootScreen(db: db, prefs: prefs),
        );
      },
    );
  }
}

/// Boots into the five-tab shell on the active property; falls back to
/// first-run place creation when the database has no properties.
class RootScreen extends StatefulWidget {
  RootScreen({super.key, required this.db, required this.prefs});

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
    final properties =
        await (widget.db.select(widget.db.properties)
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
    final created = await showNewPlaceDialog(context, widget.db);
    if (created == null) return;
    widget.prefs.activePropertyId = created.id;
    _resolveActive();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(body: SizedBox.shrink());
    }
    // A computer never starts a property from nothing (D-024): the phone's
    // walkthrough and ADD A PLACE don't apply here. It brings the record
    // over and reopens on the copy.
    if (isDesk && _active == null) {
      return DesktopIntakeScreen(db: widget.db, prefs: widget.prefs);
    }
    // First run: the walkthrough comes before anything is asked of you.
    if (!isDesk && !widget.prefs.hasSeenOnboarding) {
      return OnboardingScreen(
        prefs: widget.prefs,
        onDone: () => setState(() {}),
      );
    }
    final active = _active;
    if (active == null) {
      // First run — no places yet.
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Spacer(),
                Kicker('Local-first field journal'),
                const SizedBox(height: 8),
                Text(
                  'FIELD\nNOTES',
                  style: TextStyle(
                    fontFamily: Type.slab,
                    fontWeight: FontWeight.w900,
                    fontSize: 52,
                    height: 0.9,
                    color: Press.ink,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'The record lives on this phone. It works with the radio '
                  'off. Add the land you walk — owned, leased, public, or a '
                  'collection site.',
                  style: TextStyle(
                    fontFamily: Type.serif,
                    fontSize: 16.5,
                    height: 1.5,
                  ),
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
    // Desk companion (design README §4) on desktop platforms; the five-tab
    // handheld shell everywhere else.
    if (isDesk) {
      return DesktopShell(
        db: widget.db,
        property: active,
        prefs: widget.prefs,
        onSwitchProperty: _switchTo,
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
  BuildContext context,
  FieldNotesDb db,
  Property property,
) async {
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
    final at = await deliverFile(
      zipPath,
      text: 'Field Notes export — ${property.name}',
    );
    if (at != null && isDesk) {
      messenger.showSnackBar(SnackBar(content: Text('SAVED $at')));
    }
  } catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('EXPORT FAILED: $e')));
  }
}
