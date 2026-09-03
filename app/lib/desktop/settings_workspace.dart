import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../db/database.dart';
import '../main.dart' show exportAndShare;
import '../screens/backup_screen.dart';
import '../screens/drive_backup_screen.dart';
import '../screens/kml_import_screen.dart';
import '../screens/photo_import_screen.dart';
import '../screens/programs_screen.dart';
import '../screens/restore_screen.dart';
import '../screens/review_feed_screen.dart';
import '../screens/species_id_settings_screen.dart';
import '../screens/species_import_screen.dart';
import '../services/app_prefs.dart';
import '../map/imagery_sources.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';
import 'receive_backup_panel.dart';

/// The desk's Settings (D-024): the same groups as the phone's Settings
/// tab, laid out for a wide window, plus the four principles that used to
/// sit under every workspace — they belong in About, not on every page.
class SettingsWorkspace extends StatefulWidget {
  SettingsWorkspace({
    super.key,
    required this.db,
    required this.property,
    required this.prefs,
  });
  final FieldNotesDb db;
  final Property property;
  final AppPrefs prefs;

  @override
  State<SettingsWorkspace> createState() => _SettingsWorkspaceState();
}

class _SettingsWorkspaceState extends State<SettingsWorkspace> {
  String _version = '…';
  int _versionTaps = 0;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() => _version = '${info.version}+${info.buildNumber}');
      }
    });
  }

  void _push(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  /// Same easter egg as the phone (D-023): seven taps on the version.
  void _versionTapped() {
    if (widget.prefs.pressUnlocked) return;
    _versionTaps++;
    if (_versionTaps < 7) {
      if (_versionTaps >= 4) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              content: Text('${7 - _versionTaps} more…'),
              duration: const Duration(milliseconds: 700),
            ),
          );
      }
      return;
    }
    widget.prefs.pressUnlocked = true;
    widget.prefs.skinName = 'press';
  }

  @override
  Widget build(BuildContext context) {
    final prefs = widget.prefs;
    return ListView(
      padding: EdgeInsets.fromLTRB(18, 14, 18, 24),
      children: [
        _group('Pairing & backup', [
          _panel(ReceiveBackupPanel(padding: EdgeInsets.zero)),
          _row(
            'Google Drive',
            'The same hidden app folder the phone backs up to — back up, '
                'verify, or restore from it.',
            prefs.driveEmail ?? 'Not connected',
            () => _push(DriveBackupScreen(db: widget.db, prefs: prefs)),
          ),
          _row(
            'Encrypted backup on this computer',
            'Passphrase + 12-word recovery kit; share the zip anywhere.',
            '',
            () => _push(BackupScreen(db: widget.db, prefs: prefs)),
          ),
          _row(
            'Restore from a backup file',
            'A zip from the phone, or a copy you kept.',
            '',
            () => _push(RestoreScreen()),
          ),
          _row(
            'Export all data',
            'One folder in open formats — CSV, GeoJSON, KML, photos, the '
                'database itself. Nothing held back.',
            '',
            () => exportAndShare(context, widget.db, widget.property),
          ),
        ]),
        _group('Data', [
          _row(
            'Import boundary & zones',
            'KML / KMZ / GeoJSON from Google Earth, onX, or the county GIS.',
            '',
            () => _push(
              KmlImportScreen(db: widget.db, property: widget.property),
            ),
          ),
          _row(
            'Import photos',
            'Geotagged photos become records where they were taken.',
            '',
            () => _push(
              PhotoImportScreen(
                db: widget.db,
                property: widget.property,
                prefs: prefs,
              ),
            ),
          ),
          _row(
            'Import species list',
            'A CSV of the plants you work with.',
            '',
            () => _push(
              SpeciesImportScreen(db: widget.db, property: widget.property),
            ),
          ),
          _row(
            'Programs',
            'EQIP · TPWD · cost-share practices and deadlines.',
            '',
            () =>
                _push(ProgramsScreen(db: widget.db, property: widget.property)),
          ),
        ]),
        _group('Species ID', [
          _row(
            'Photo identification',
            'Pl@ntNet, with your own key. Suggestions never enter the record '
                'without your say.',
            '',
            () => _push(SpeciesIdSettingsScreen()),
          ),
        ]),
        _group('Sharing', [
          _row(
            'Review',
            'Edits by contributors awaiting your ruling, and the rulings made.',
            '',
            () => _push(
              ReviewFeedScreen(db: widget.db, property: widget.property),
            ),
          ),
        ]),
        _group('Display & network', [
          _row(
            'Satellite imagery',
            activeImagery.id == 'esri'
                ? 'Esri World Imagery — sharper, to zoom 19. Display only; '
                      'offline capture stays USGS.'
                : 'USGS — public domain, to zoom 16.',
            activeImagery.id == 'esri' ? 'Esri' : 'USGS',
            () => setState(() {
              final next = activeImagery.id == 'esri' ? 'usgs' : 'esri';
              prefs.imagerySource = next;
              activeImagery = imageryById(next);
            }),
          ),
          _row(
            'Ledger rows',
            prefs.density == 'dense'
                ? 'Dense — more on screen.'
                : 'Glove — big targets, as on the phone.',
            prefs.density == 'dense' ? 'Dense' : 'Glove',
            () => setState(
              () =>
                  prefs.density = prefs.density == 'dense' ? 'glove' : 'dense',
            ),
          ),
          _row(
            'Automatic backup',
            'Daily to the encrypted store on this computer; weekly check.',
            prefs.autoBackup ? 'On' : 'Off',
            () => setState(() => prefs.autoBackup = !prefs.autoBackup),
          ),
          _row(
            'Weather & soil for each record',
            prefs.envContext
                ? 'Sends a coarsened location (~1 km) to Open-Meteo and '
                      'USDA-NRCS.'
                : 'Off — nothing leaves for this.',
            prefs.envContext ? 'On' : 'Off',
            () => setState(() => prefs.envContext = !prefs.envContext),
          ),
        ]),
        if (prefs.pressUnlocked)
          _group('Appearance', [
            _row(
              'Skin',
              prefs.skinName == 'press'
                  ? 'Field Station — paper, ink and the press.'
                  : 'Quiet — the plain one.',
              prefs.skinName == 'press' ? 'Press' : 'Quiet',
              () => setState(
                () => prefs.skinName = prefs.skinName == 'press'
                    ? 'quiet'
                    : 'press',
              ),
            ),
          ]),
        _group('About', [
          _row('Version', 'Field Notes', _version, _versionTapped),
        ]),
        _heading('How this desk works'),
        _principleGrid(const [
          (
            'Source of truth',
            'The phone is where records are born. This desk works on a copy '
                'of that record — editing, reviewing, exporting — and invents '
                'nothing of its own.',
          ),
          (
            'Permissions',
            'Roles are enforced in the data, not just the buttons. A greyed '
                'button is a courtesy; the permission system is underneath.',
          ),
          (
            'Suggestions',
            'Species suggestions accumulate quietly. Nothing enters the '
                'record without your acceptance.',
          ),
          (
            'Numbers',
            'Nothing here is a new number. Every figure — survival, counts, '
                'acreage — derives from rows the field device wrote.',
          ),
        ]),
        SizedBox(height: 18),
        _group('Privacy', [
          _row(
            'Account',
            'None — everything stays on this computer.',
            'None',
            null,
          ),
          _row(
            'Analytics',
            'None. No telemetry, no crash reports.',
            'Off',
            null,
          ),
        ]),
      ],
    );
  }

  Widget _group(String label, List<Widget> rows) => Padding(
    padding: EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonoLabel(label, size: 9, spacing: 1.8, color: Press.oxblood),
        SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Press.paperRaised,
            border: Border.all(color: Press.borderInk, width: 1.5),
          ),
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) Container(height: 1, color: Press.divider),
                rows[i],
              ],
            ],
          ),
        ),
      ],
    ),
  );

  Widget _panel(Widget child) =>
      Padding(padding: EdgeInsets.all(12), child: child);

  Widget _row(String title, String sub, String value, VoidCallback? onTap) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 16,
                        color: Press.ink,
                      ),
                    ),
                    if (sub.isNotEmpty) ...[
                      SizedBox(height: 3),
                      Text(
                        sub,
                        style: TextStyle(
                          fontFamily: Type.serif,
                          fontSize: 13.5,
                          height: 1.4,
                          color: Press.inkSoft,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (value.isNotEmpty) ...[
                SizedBox(width: 12),
                MonoLabel(value, size: 9.5, opacity: 0.75),
              ],
              if (onTap != null) ...[
                SizedBox(width: 6),
                Icon(Icons.chevron_right, size: 18, color: Press.inkSoft),
              ],
            ],
          ),
        ),
      );

  Widget _heading(String label) => Padding(
    padding: EdgeInsets.only(bottom: 8),
    child: MonoLabel(label, size: 9, spacing: 1.8, color: Press.oxblood),
  );

  /// The four principles as a 2×2 grid of cards — the old cells under every
  /// workspace, now in the one place they belong.
  Widget _principleGrid(List<(String, String)> items) {
    Widget card((String, String) it) => Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Press.paperRaised,
        border: Border.all(color: Press.borderInk, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MonoLabel(it.$1, size: 9, spacing: 1.8, color: Press.oxblood),
          SizedBox(height: 6),
          Text(
            it.$2,
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 14.5,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
    return Column(
      children: [
        for (var i = 0; i < items.length; i += 2)
          Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: card(items[i])),
                  SizedBox(width: 10),
                  Expanded(
                    child: i + 1 < items.length
                        ? card(items[i + 1])
                        : SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
