import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import '../screens/backup_screen.dart';
import '../screens/kml_import_screen.dart';
import '../screens/drive_backup_screen.dart';
import '../screens/review_feed_screen.dart';
import '../screens/lan_backup_screen.dart';
import '../screens/offline_maps_screen.dart';
import '../screens/onboarding_screen.dart';
import '../screens/photo_import_screen.dart';
import '../screens/programs_screen.dart';
import '../screens/species_id_settings_screen.dart';
import '../screens/species_import_screen.dart';
import '../screens/sync_screen.dart';
import '../sync/sync_service.dart';
import '../screens/restore_screen.dart';
import '../map/imagery_sources.dart';
import '../services/app_prefs.dart';
import '../services/press_unlock.dart';
import '../theme/tokens.dart';
import '../main.dart' show exportAndShare, opLog;
import '../widgets/press.dart';

/// Settings & backup (design README §3.6). Order is the argument:
/// verification first, storage second, then the grouped tables, then export.
class SettingsTab extends StatefulWidget {
  SettingsTab({
    super.key,
    required this.db,
    required this.property,
    required this.prefs,
  });

  final FieldNotesDb db;
  final Property property;
  final AppPrefs prefs;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  /// Taps on the version row since the last timeout. Seven finds the press.
  String? _lastBackup;
  String? _lastVerify;
  bool _basemapInstalled = false;
  int _basemapBytes = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadVersion();
    _loadSync();
    PressUnlock.revealIfPending(this);
  }

  Future<void> _load() async {
    final docs = await getApplicationDocumentsDirectory();
    final config = File(p.join(docs.path, 'backup_config.json'));
    String? lastBackup;
    String? lastVerify;
    if (config.existsSync()) {
      try {
        final data =
            jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
        lastBackup = data['last_backup'] as String?;
        lastVerify = data['last_verify'] as String?;
      } catch (_) {}
    }
    final basemap = File(p.join(docs.path, 'basemap', 'basemap.pmtiles'));
    // "Current" means nothing has changed since — not merely "recent".
    var unbacked = 0;
    if (lastBackup != null) {
      final changed = await (widget.db.select(
        widget.db.observations,
      )..where((o) => o.updatedAt.isBiggerThan(Constant(lastBackup!)))).get();
      unbacked = changed.length;
    }
    if (mounted) {
      setState(() {
        _lastBackup = lastBackup;
        _lastVerify = lastVerify;
        _unbacked = unbacked;
        _basemapInstalled = basemap.existsSync();
        _basemapBytes = basemap.existsSync() ? basemap.lengthSync() : 0;
      });
    }
  }

  int _unbacked = 0;

  String _ago(String? iso) {
    if (iso == null) return 'never';
    final then = DateTime.tryParse(iso);
    if (then == null) return iso;
    final d = DateTime.now().toUtc().difference(then);
    if (d.inDays > 0) return '${d.inDays} d ago';
    if (d.inHours > 0) return '${d.inHours} h ago';
    return 'just now';
  }

  String _syncLine = 'edits cross both ways through your Drive';

  Future<void> _loadSync() async {
    final log = opLog;
    if (log == null || widget.prefs.driveEmail == null) return;
    final s = SyncService(widget.db, widget.prefs, log);
    final at = await s.lastSyncAt;
    final pending = await s.pending;
    if (!mounted) return;
    setState(() {
      _syncLine = [
        at == null ? 'never synced' : 'synced ${_ago(at)}',
        if (pending > 0) '$pending waiting',
      ].join(' · ');
    });
  }

  /// Nag logic (spec §11.8): banner after 14 days without a backup.
  bool get _backupOverdue {
    if (_lastBackup == null) return true;
    final then = DateTime.tryParse(_lastBackup!);
    return then == null || DateTime.now().toUtc().difference(then).inDays >= 14;
  }

  @override
  Widget build(BuildContext context) {
    // Sage = nothing to do. Ochre = changes waiting. Oxblood = overdue.
    final backupHealthy = !_backupOverdue;
    final cardColor = !backupHealthy
        ? Press.oxblood
        : _unbacked > 0
        ? Press.ochre
        : Press.sage;
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: EdgeInsets.only(bottom: 110),
        children: [
          ScreenHeader(
            kicker: 'Configuration · this device',
            title: 'Settings',
          ),
          SizedBox(height: 12),

          // 1. Backup card — verification first.
          Padding(
            padding: EdgeInsets.symmetric(horizontal: Metrics.gutter),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: cardColor, width: 1.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    color: cardColor,
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Diamond(size: 9, color: Press.paper),
                        SizedBox(width: 7),
                        MonoLabel(
                          !backupHealthy
                              ? 'Backup needed'
                              : _unbacked > 0
                              ? '$_unbacked ${_unbacked == 1 ? 'change' : 'changes'} since backup'
                              : _lastVerify != null
                              ? 'Backup verified'
                              : 'Backup current — unverified',
                          size: 10,
                          spacing: 1.6,
                          color: Press.paper,
                        ),
                        Spacer(),
                        MonoLabel(
                          _ago(_lastBackup),
                          size: 9,
                          color: Press.paper,
                          opacity: 0.85,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _lastBackup == null
                              ? 'Nothing is backed up yet. A phone in the '
                                    'creek is a total loss until this runs.'
                              : 'Only what changed gets copied, so it\'s '
                                    'quick. Last verified ${_ago(_lastVerify)} '
                                    '— an untested backup is not a backup.',
                          style: TextStyle(
                            fontFamily: Type.serif,
                            fontSize: 15.5,
                            height: 1.45,
                          ),
                        ),
                        SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: () => Navigator.of(context)
                                    .push(
                                      MaterialPageRoute(
                                        builder: (_) => BackupScreen(
                                          db: widget.db,
                                          prefs: widget.prefs,
                                        ),
                                      ),
                                    )
                                    .then((_) => _load()),
                                child: Text('BACK UP NOW'),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => RestoreScreen(),
                                  ),
                                ),
                                child: Text('RESTORE'),
                              ),
                            ),
                          ],
                        ),
                        // One tap to Drive (Austin, 2026-09-07). Opens the
                        // Drive screen already uploading, so what leaves the
                        // phone is still shown step by step.
                        SizedBox(height: 8),
                        SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            icon: Icon(Icons.cloud_upload_outlined, size: 18),
                            label: Text(
                              widget.prefs.driveEmail == null
                                  ? 'BACK UP TO GOOGLE DRIVE'
                                  : 'BACK UP TO DRIVE · ${widget.prefs.driveEmail}',
                              overflow: TextOverflow.ellipsis,
                            ),
                            onPressed: () => Navigator.of(context)
                                .push(
                                  MaterialPageRoute(
                                    builder: (_) => DriveBackupScreen(
                                      db: widget.db,
                                      prefs: widget.prefs,
                                      autoRun: true,
                                    ),
                                  ),
                                )
                                .then((_) => _load()),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 18),

          // 2. Grouped tables.
          _group('Offline maps', [
            (
              'Satellite imagery',
              activeImagery.id == 'esri'
                  ? 'Esri — sharper, to zoom 19 · display only'
                  : 'USGS — public domain, to zoom 16',
              activeImagery.id == 'esri' ? 'Esri' : 'USGS',
              () {
                final next = activeImagery.id == 'esri' ? 'usgs' : 'esri';
                widget.prefs.imagerySource = next;
                activeImagery = imageryById(next);
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Imagery: ${activeImagery.label}. The map redraws '
                      'next time it reloads.',
                    ),
                  ),
                );
              },
            ),
            (
              'Offline basemap',
              _basemapInstalled
                  ? 'stored on this phone · works with no signal'
                  : 'none yet · use ⌗ Capture area on the map',
              _basemapInstalled
                  ? '${(_basemapBytes / (1 << 20)).toStringAsFixed(0)} MB'
                  : 'None',
              () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => OfflineMapsScreen()))
                  .then((_) => _load()),
            ),
          ]),
          _group('Data', [
            (
              'Import boundary & zones',
              'KML / KMZ / GeoJSON from Google Earth, onX, or your county GIS',
              '',
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      KmlImportScreen(db: widget.db, property: widget.property),
                ),
              ),
            ),
            (
              'Import photos',
              'geotagged photos become records where they were taken',
              '',
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PhotoImportScreen(
                    db: widget.db,
                    property: widget.property,
                    prefs: widget.prefs,
                  ),
                ),
              ),
            ),
            (
              'Import species list',
              'optional · a CSV of your own species, starred for quick pick',
              '',
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SpeciesImportScreen(
                    db: widget.db,
                    property: widget.property,
                  ),
                ),
              ),
            ),
            (
              'Programs',
              'EQIP · state wildlife plans · cost-share practices and deadlines',
              '',
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      ProgramsScreen(db: widget.db, property: widget.property),
                ),
              ),
            ),
          ]),
          _group('Species ID', [
            (
              'Photo identification',
              'your own Pl@ntNet and AI keys · the app suggests, you decide',
              '',
              () => Navigator.of(context)
                  .push(
                    MaterialPageRoute(
                      builder: (_) => SpeciesIdSettingsScreen(),
                    ),
                  )
                  .then((_) => _load()),
            ),
          ]),
          _group('Backup', [
            (
              'Pair with a computer',
              'over your own network · nothing touches the internet',
              '',
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      LanBackupScreen(db: widget.db, prefs: widget.prefs),
                ),
              ),
            ),
            (
              'Back up to Google Drive',
              'a hidden folder in your own Drive · encrypted before it leaves',
              '',
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      DriveBackupScreen(db: widget.db, prefs: widget.prefs),
                ),
              ),
            ),
            (
              'Sync with the desk',
              _syncLine,
              widget.prefs.driveEmail == null
                  ? ''
                  : widget.prefs.driveSync
                  ? 'On'
                  : 'Off',
              () => Navigator.of(context)
                  .push(
                    MaterialPageRoute(
                      builder: (_) =>
                          SyncScreen(db: widget.db, prefs: widget.prefs),
                    ),
                  )
                  .then((_) => _loadSync()),
            ),
          ]),
          _group('Sharing', [
            (
              'Review',
              'edits by other stewards wait here for your say · final, always',
              '',
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ReviewFeedScreen(
                    db: widget.db,
                    property: widget.property,
                  ),
                ),
              ),
            ),
          ]),
          _group('Help', [
            (
              'Getting started',
              'the walkthrough — what the app is for and how it behaves',
              '',
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => OnboardingScreen(prefs: widget.prefs),
                ),
              ),
            ),
          ]),
          // Spec §7 field ergonomics. Tapping a row toggles it.
          _group('Display', [
            (
              'Outdoor mode',
              widget.prefs.outdoorMode
                  ? 'bigger type for sun and gloves'
                  : 'standard type · tap for bigger, for sun and gloves',
              widget.prefs.outdoorMode ? 'On' : 'Off',
              () => setState(
                () => widget.prefs.outdoorMode = !widget.prefs.outdoorMode,
              ),
            ),
            (
              'Ledger rows',
              widget.prefs.density == 'dense'
                  ? 'dense · more entries per screen'
                  : 'glove · roomy rows, easy to hit',
              widget.prefs.density == 'dense' ? 'Dense' : 'Glove',
              () => setState(
                () => widget.prefs.density = widget.prefs.density == 'dense'
                    ? 'glove'
                    : 'dense',
              ),
            ),
          ]),
          // D-016: off-grid users, metered LTE. Tapping a row toggles it.
          _group('Network', [
            (
              'Cellular downloads',
              widget.prefs.allowCellular
                  ? 'maps and backups may use mobile data'
                  : 'maps and backups wait for Wi-Fi · tap to allow cellular',
              widget.prefs.allowCellular ? 'On' : 'Off',
              () => setState(
                () => widget.prefs.allowCellular = !widget.prefs.allowCellular,
              ),
            ),
            (
              'Automatic backup',
              widget.prefs.autoBackup
                  ? 'once a day while you use the app · weekly check'
                  : 'off · only when you tap Back up now',
              widget.prefs.autoBackup ? 'On' : 'Off',
              () => setState(
                () => widget.prefs.autoBackup = !widget.prefs.autoBackup,
              ),
            ),
            (
              'Drive auto-backup',
              !widget.prefs.autoBackup
                  ? 'needs Automatic backup on'
                  : widget.prefs.driveEmail == null
                  ? 'connect Google Drive first (Backup · below)'
                  : widget.prefs.driveAutoBackup
                  ? 'once a day on Wi-Fi · ${widget.prefs.driveEmail}'
                  : 'off · only when you tap Back up to Drive',
              widget.prefs.driveAutoBackup ? 'On' : 'Off',
              () => setState(
                () => widget.prefs.driveAutoBackup =
                    !widget.prefs.driveAutoBackup,
              ),
            ),
            // Off by default and described in terms of what leaves the phone
            // rather than what you get (D-022). It is the only switch here
            // that turns on an unprompted request to a third party.
            (
              'Weather & soil for each record',
              widget.prefs.envContext
                  ? 'on · sends a location rounded to about a kilometre to '
                        'Open-Meteo and USDA-NRCS'
                  : 'off · nothing is looked up and no location is sent',
              widget.prefs.envContext ? 'On' : 'Off',
              () => setState(
                () => widget.prefs.envContext = !widget.prefs.envContext,
              ),
            ),
          ]),
          if (widget.prefs.pressUnlocked)
            _group('Appearance', [
              (
                'Skin',
                widget.prefs.skinName == 'press'
                    ? 'Field Station — paper, ink and the press'
                    : 'Quiet — the plain one',
                widget.prefs.skinName == 'press' ? 'Press' : 'Quiet',
                () => setState(
                  () => widget.prefs.skinName = widget.prefs.skinName == 'press'
                      ? 'quiet'
                      : 'press',
                ),
              ),
            ]),
          _group('About', [
            ('Version', 'Field Notes', _appVersion, _versionTapped),
          ]),
          _group('Privacy', [
            ('Account', 'none — everything stays on this phone', 'None', null),
            (
              'Analytics',
              'no record content, no coordinates, ever',
              'Off',
              null,
            ),
          ]),

          SizedBox(height: 10),

          // 4. Export all data.
          Padding(
            padding: EdgeInsets.symmetric(horizontal: Metrics.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 58,
                  child: OutlinedButton(
                    onPressed: () => _export(context),
                    child: Text(
                      'EXPORT ALL DATA',
                      style: TextStyle(
                        fontFamily: Type.slab,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 7),
                MonoLabel(
                  'database.sqlite · data/*.csv · geo/*.geojson + '
                  'property.kml · media with EXIF GPS · zipped to the share '
                  'sheet',
                  size: 9,
                  opacity: 0.65,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Read from the package itself, never hardcoded — the row is
  /// load-bearing (the seven-tap unlock lives on it) and a stale string
  /// here would lie about the very build being tapped on (audit P2).
  String _appVersion = '…';

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _appVersion = '${info.version}+${info.buildNumber}');
    }
  }

  late final _unlock = PressUnlock(widget.prefs);

  void _versionTapped() => _unlock.tap(context);

  Widget _group(
    String label,
    List<(String, String, String, VoidCallback?)> rows,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Metrics.gutter, 0, Metrics.gutter, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MonoLabel(label, size: 9, spacing: 2),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++)
                  InkWell(
                    onTap: rows[i].$4,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 58),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: Press.paperRaised,
                        border: i < rows.length - 1
                            ? Border(
                                bottom: BorderSide(
                                  color: Press.divider,
                                  width: 1,
                                ),
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  rows[i].$1.toUpperCase(),
                                  style: TextStyle(
                                    fontFamily: Type.slab,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14.5,
                                    color: Press.ink,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                MonoLabel(rows[i].$2, size: 9, opacity: 0.7),
                              ],
                            ),
                          ),
                          if (rows[i].$3.isNotEmpty)
                            MonoLabel(
                              rows[i].$3,
                              size: 10.5,
                              spacing: 1.4,
                              color: Press.oxblood,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context) async {
    // Delegates to the existing zip+share flow living on PropertyScreen; a
    // shared exporter call keeps this button honest.
    await exportAndShare(context, widget.db, widget.property);
  }
}
