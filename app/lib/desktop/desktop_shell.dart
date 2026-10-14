import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import '../services/app_prefs.dart';
import '../services/press_unlock.dart';
import '../main.dart' show opLog;
import '../sync/sync_service.dart';
import '../sync/sync_status.dart';
import '../widgets/passphrase_dialog.dart';
import '../services/review.dart';
import '../widgets/nativity_chip.dart';
import '../widgets/removal_chip.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';
import '../backup/restore.dart';
import '../screens/drive_backup_screen.dart';
import '../screens/record_detail_screen.dart';
import '../tabs/grow_tab.dart';
import '../tabs/ledger_tab.dart';
import '../tabs/species_tab.dart';
import 'desk_map_view.dart';
import 'drive_watch.dart';
import '../services/map_jump.dart';
import 'export_workspace.dart';
import 'settings_workspace.dart';
import '../services/diag.dart';

part 'desktop_shell/core.dart';
part 'desktop_shell/status.dart';
part 'desktop_shell/review.dart';

/// Desk companion (design README §4): a single window shell — title bar,
/// nav, workspace, status bar, principle cells. The phone is the source of
/// truth; data arrives here by restore-from-zip.
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.db,
    required this.property,
    required this.prefs,
    required this.onSwitchProperty,
  });

  /// The desk holds every place the phone knows; the title bar switches.
  final ValueChanged<Property> onSwitchProperty;

  final FieldNotesDb db;
  final Property property;
  final AppPrefs prefs;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

/// Split along its concerns (D-038 item 7): state in `desktop_shell/
/// core.dart`, sync/Drive/status in `status.dart`, the Review workspace
/// in `review.dart`. The frame — title bar, nav, workspaces — stays here.
class _DesktopShellState extends State<DesktopShell>
    with WidgetsBindingObserver, _DesktopShellCore, _DesktopShellStatus {
  /// The phone's five tabs, in the phone's order, plus the desk's two
  /// (Austin, 2026-09-04: "the two apps completely aligned and familiar
  /// with each other").
  static const _views = [
    'Map',
    'Ledger',
    'Grow',
    'Species',
    'Review',
    'Export',
    'Settings',
  ];

  @override
  void initState() {
    super.initState();
    // The press unlock re-keys the root, so this shell is brand new:
    // come back up on Settings, where the person was, and deliver the
    // reveal the old tree couldn't (audit 2026-09-05).
    if (PressUnlock.takePending()) {
      _view = _views.indexOf('Settings');
      PressUnlock.reveal(this);
    }
    WidgetsBinding.instance.addObserver(this);
    mapJump.addListener(_onMapJump);
    _checkDrive();
    _autoSync();
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (_) => _autoSync());
    // The title bar's size / media / places readouts follow the journal;
    // loaded-once numbers went stale after an import or ADD PHOTOS
    // (audit 2026-09-04). The watch emits once on listen, so it is also
    // the first load — taken at once, the title bar must not open blank;
    // a photo import writes per photo, so later bursts settle before the
    // counts are re-read.
    var first = true;
    _statusWatch = widget.db
        .changes({
          widget.db.media,
          widget.db.properties,
          widget.db.observations,
        })
        .listen((_) {
          if (first) {
            first = false;
            _loadStatus();
            _loadSyncStatus();
            return;
          }
          _statusDebounce?.cancel();
          _statusDebounce = Timer(const Duration(milliseconds: 250), () {
            _loadStatus();
            _loadSyncStatus();
          });
        });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    mapJump.removeListener(_onMapJump);
    _syncTimer?.cancel();
    _statusDebounce?.cancel();
    _statusWatch?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _autoSync();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Press.paperEdge,
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 1400),
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Press.paper,
                      border: Border.all(color: Press.borderInk, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x6B14120C),
                          offset: Offset(0, 34),
                          blurRadius: 60,
                          spreadRadius: -26,
                        ),
                        BoxShadow(
                          color: Color(0x3814120C),
                          offset: Offset(0, 10),
                          blurRadius: 22,
                          spreadRadius: -14,
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        _titleBar(),
                        _navBar(),
                        _driveBanner(),
                        Expanded(child: _workspace()),
                        _statusBar(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBar() {
    return Container(
      color: Press.ink,
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(right: 6),
              child: Opacity(
                opacity: 0.5,
                child: Diamond(size: 7, color: Press.paper),
              ),
            ),
          SizedBox(width: 8),
          // The place switcher lives in the title: every property the phone
          // knows is here, and the desk is never stuck on the first one.
          PopupMenuButton<Property>(
            tooltip: 'Switch place',
            color: Press.paper,
            onSelected: widget.onSwitchProperty,
            itemBuilder: (_) => [
              for (final p in _properties)
                PopupMenuItem(
                  value: p,
                  child: Text(
                    p.name,
                    style: TextStyle(
                      fontFamily: Type.serif,
                      fontSize: 15,
                      fontWeight: p.id == widget.property.id
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MonoLabel(
                  'Field Notes · ${widget.property.name}',
                  size: 10.5,
                  spacing: 1.6,
                  color: Press.paper,
                ),
                Icon(Icons.arrow_drop_down, size: 18, color: Press.paper),
              ],
            ),
          ),
          SizedBox(width: 16),
          Flexible(
            child: MonoLabel(
              '${(_dbBytes / (1 << 20)).toStringAsFixed(1)} MB · $_mediaCount media',
              size: 9.5,
              color: Press.paper,
              opacity: 0.72,
              maxLines: 1,
            ),
          ),
          Spacer(),
          Diamond(size: 8, color: Press.sage, blink: true),
          SizedBox(width: 6),
          Flexible(
            child: MonoLabel(
              _copyLine,
              size: 9.5,
              color: Press.paper,
              opacity: 0.9,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _navBar() {
    return Container(
      decoration: BoxDecoration(
        color: Press.paperEdge,
        border: Border(bottom: BorderSide(color: Press.borderInk, width: 2)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _views.length; i++)
            InkWell(
              onTap: () => setState(() => _view = i),
              child: Container(
                constraints: BoxConstraints(minHeight: 50),
                padding: EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: i == _view ? Press.paper : null,
                  border: Border(
                    right: BorderSide(color: Color(0x331B1813), width: 1),
                  ),
                  boxShadow: i == _view
                      ? [
                          BoxShadow(
                            color: Press.oxblood,
                            offset: Offset(0, -3),
                            blurRadius: 0,
                            spreadRadius: -18,
                          ),
                        ]
                      : null,
                ),
                child: Opacity(
                  opacity: i == _view ? 1 : 0.75,
                  child: Row(
                    children: [
                      Diamond(
                        size: 8,
                        color: i == _view
                            ? Press.oxblood
                            : Press.inkSoft.withValues(alpha: 0.4),
                      ),
                      SizedBox(width: 7),
                      MonoLabel(
                        _views[i],
                        size: 10,
                        spacing: 1.6,
                        color: Press.ink,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// A jump names a place (D-029): switch to it if it isn't the one open,
  /// and show the map. The map workspace flies once it has the subject.
  Future<void> _onMapJump() async {
    final j = mapJump.value;
    if (j == null) return;
    if (j.propertyId != widget.property.id) {
      final p = await (widget.db.select(
        widget.db.properties,
      )..where((x) => x.id.equals(j.propertyId))).getSingleOrNull();
      if (p == null) {
        mapJump.value = null;
        return;
      }
      widget.onSwitchProperty(p);
    }
    if (mounted && _view != 0) setState(() => _view = 0);
  }

  /// Workspaces a person has actually opened. The stack keeps their state
  /// alive after that, but nothing builds — or fetches — before its first
  /// visit: at launch the Export bench was already rendering pages and
  /// requesting imagery for a tab nobody had opened (audit 2026-09-04).
  final Set<int> _visited = {};

  /// In `_views` order.
  late final List<Widget Function()> _builders = [
    () => DeskMapWorkspace(db: widget.db, property: widget.property),
    () => LedgerTab(
      db: widget.db,
      property: widget.property,
      prefs: widget.prefs,
    ),
    () => GrowTab(db: widget.db, property: widget.property),
    () => SpeciesTab(db: widget.db, property: widget.property),
    () => _ReviewWorkspace(db: widget.db, property: widget.property),
    () => ExportWorkspace(db: widget.db, property: widget.property),
    () => SettingsWorkspace(
      db: widget.db,
      property: widget.property,
      prefs: widget.prefs,
    ),
  ];

  Widget _workspace() {
    // IndexedStack, not a switch: composing a plate, then checking one
    // record in Review, must come back to the same plate (design audit
    // 2026-09-03 finding 1). Keyed by property so switching place resets.
    // Visited is marked here, where the view is shown, so any path that
    // sets `_view` gets a built workspace.
    _visited.add(_view);
    return IndexedStack(
      key: ValueKey(widget.property.id),
      index: _view,
      children: [
        for (var i = 0; i < _builders.length; i++)
          _visited.contains(i) ? _builders[i]() : const SizedBox.shrink(),
      ],
    );
  }
}
