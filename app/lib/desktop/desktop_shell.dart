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
import 'export_workspace.dart';
import 'settings_workspace.dart';

/// Desk companion (design README §4): a single window shell — title bar,
/// nav, workspace, status bar, principle cells. The phone is the source of
/// truth; data arrives here by restore-from-zip.
class DesktopShell extends StatefulWidget {
  DesktopShell({
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

class _DesktopShellState extends State<DesktopShell>
    with WidgetsBindingObserver {
  int _view = 0;

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

  int _dbBytes = 0;
  int _mediaCount = 0;
  List<Property> _properties = const [];

  /// The phone has put a newer copy in Drive than the one this desk holds.
  DriveNews? _news;

  StreamSubscription<void>? _statusWatch;
  Timer? _statusDebounce;

  /// D-028: what this desk has that the phone doesn't yet, and when the
  /// two last spoke. Sync runs on open, on focus, and every few minutes.
  int _pendingSync = 0;
  String? _lastSync;
  bool _syncing = false;
  Timer? _syncTimer;

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
    _syncTimer?.cancel();
    _statusDebounce?.cancel();
    _statusWatch?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _autoSync();
  }

  Future<void> _autoSync() async {
    final log = opLog;
    if (log == null) return;
    final r = await SyncService(
      widget.db,
      widget.prefs,
      log,
    ).maybeRunAutomatic().catchError((_) => null);
    if (r != null) _loadSyncStatus();
  }

  Future<void> _loadSyncStatus() async {
    final log = opLog;
    if (log == null) return;
    final s = SyncService(widget.db, widget.prefs, log);
    final pending = await s.pending;
    final at = await s.lastSyncAt;
    if (mounted) {
      setState(() {
        _pendingSync = pending;
        _lastSync = at;
      });
    }
  }

  Future<void> _syncNow() async {
    final log = opLog;
    if (log == null) return;
    setState(() => _syncing = true);
    final r = await SyncService(widget.db, widget.prefs, log).sync(
      interactive: true,
      askPassphrase: () => askPassphraseDialog(context),
    );
    if (!mounted) return;
    setState(() => _syncing = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(r.summary.toUpperCase())));
    _loadSyncStatus();
    _checkDrive();
  }

  Future<void> _checkDrive() async {
    final news = await checkDriveForNewer(widget.prefs);
    if (mounted) setState(() => _news = news);
  }

  /// Synced desk (D-028): the only thing worth a banner is work here the
  /// phone hasn't got. Before the first sync, the old one-way mirror
  /// banner (D-024) still says a newer copy is waiting in Drive.
  Widget _driveBanner() {
    if (widget.prefs.driveEmail != null && _properties.isNotEmpty) {
      if (_lastSync != null && _pendingSync == 0) return SizedBox.shrink();
      return Container(
        color: Press.sageLight,
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Diamond(size: 9, color: Press.sage, filled: true),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                _lastSync == null
                    ? 'This desk has not synced with the phone yet.'
                    : '$_pendingSync ${_pendingSync == 1 ? 'edit' : 'edits'} '
                          'on this desk not yet on the phone.',
                style: TextStyle(
                  fontFamily: Type.serif,
                  fontSize: 14,
                  color: Press.ink,
                ),
              ),
            ),
            SizedBox(width: 12),
            SizedBox(
              height: 36,
              child: FilledButton(
                onPressed: _syncing ? null : _syncNow,
                child: Text(_syncing ? 'SYNCING…' : 'SYNC NOW'),
              ),
            ),
          ],
        ),
      );
    }
    final news = _news;
    if (news == null) return SizedBox.shrink();
    final when = news.createdAt.replaceFirst('T', ' ');
    final stamp = when.length >= 16 ? when.substring(0, 16) : when;
    return Container(
      color: Press.sageLight,
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Diamond(size: 9, color: Press.sage, filled: true),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'The phone has put a newer copy in Drive (generation '
              '${news.generation}, $stamp UTC). This desk is a mirror — '
              'bring it over to see what the phone sees.',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 14,
                color: Press.ink,
              ),
            ),
          ),
          SizedBox(width: 12),
          SizedBox(
            height: 36,
            child: FilledButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DriveBackupScreen(
                      db: widget.db,
                      prefs: widget.prefs,
                      intake: true,
                    ),
                  ),
                );
                _checkDrive();
              },
              child: Text('BRING IT OVER'),
            ),
          ),
          SizedBox(width: 6),
          IconButton(
            tooltip: 'Not now',
            onPressed: () => setState(() => _news = null),
            icon: Icon(Icons.close, size: 18, color: Press.inkSoft),
          ),
        ],
      ),
    );
  }

  Future<void> _loadStatus() async {
    final docs = await getApplicationDocumentsDirectory();
    final dbFile = File(p.join(docs.path, 'field_notes.sqlite'));
    final (media, properties) = await (
      (widget.db.selectOnly(
        widget.db.media,
      )..addColumns([widget.db.media.id.count()])).getSingle(),
      (widget.db.select(widget.db.properties)
            ..where((p) => p.deletedAt.isNull())
            ..orderBy([(p) => OrderingTerm.asc(p.name)]))
          .get(),
    ).wait;
    // Where this copy came from — the honest thing to put in a title bar.
    final from = RestorePipeline(docs).lastRestoredFrom;
    String copyLine;
    if (from == null) {
      copyLine = 'Copy on this computer';
    } else {
      final src = '${from['source'] ?? ''}'.toLowerCase();
      final via = src.contains('drive')
          ? 'Drive'
          : src.contains('received')
          ? 'LAN'
          : 'file';
      final at = '${from['created_at'] ?? ''}'.replaceFirst('T', ' ');
      copyLine =
          'Copy from the phone · $via gen ${from['generation'] ?? '?'} · '
          '${at.length >= 16 ? at.substring(0, 16) : at}';
    }
    if (mounted) {
      setState(() {
        _dbBytes = dbFile.existsSync() ? dbFile.lengthSync() : 0;
        _mediaCount = media.read(widget.db.media.id.count()) ?? 0;
        _properties = properties;
        _copyLine = copyLine;
      });
    }
  }

  String _copyLine = '';

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

  /// Writes captured by the oplog and not yet carried anywhere.
  Future<int> _pendingWrites() async {
    try {
      final row = await widget.db
          .customSelect('SELECT COUNT(*) AS n FROM sync_ops')
          .getSingleOrNull();
      return (row?.data['n'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Widget _statusBar() {
    final sentences = [
      'The record in place · click a mark to open it',
      'The feed as a record of entries',
      'Lineage, cohorts, features · survival is derived, never stored',
      'The species library this place actually grows',
      'Reviewing the local store · click a row to inspect',
      'A plate is the record drawn, not a new claim about it',
      'Settings · what this desk is and how it keeps its copy',
    ];
    return Container(
      decoration: BoxDecoration(
        color: Press.paperEdge,
        border: Border(top: BorderSide(color: Press.borderInk, width: 2)),
      ),
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        children: [
          MonoLabel(sentences[_view], size: 9.5, opacity: 0.8),
          Spacer(),
          // Derived, not decorative (design audit P3): the write queue is
          // the oplog's own count, and sync is honestly off until D-026's
          // carrier work lands.
          FutureBuilder<int>(
            future: _pendingWrites(),
            builder: (context, snap) {
              final n = snap.data;
              return MonoLabel(
                n == null
                    ? 'Sync off · edits stay on this computer'
                    : n == 0
                    ? 'Nothing waiting · sync off'
                    : '$n write${n == 1 ? '' : 's'} captured · sync off',
                size: 9.5,
                opacity: 0.8,
              );
            },
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Review ─────────────────────────────

class _ReviewWorkspace extends StatefulWidget {
  _ReviewWorkspace({required this.db, required this.property});
  final FieldNotesDb db;
  final Property property;

  @override
  State<_ReviewWorkspace> createState() => _ReviewWorkspaceState();
}

class _ReviewWorkspaceState extends State<_ReviewWorkspace> {
  String? _selectedId;
  List<Observation> _rows = const [];
  final FocusNode _keys = FocusNode(debugLabel: 'review-keys');
  bool _pendingOnly = false;
  Set<String> _pendingIds = const {};
  Map<String, String> _taxonNames = const {};
  Map<String, String?> _taxonNativity = const {};
  late final _review = ReviewService(widget.db);

  StreamSubscription<void>? _pendingWatch;
  StreamSubscription<void>? _taxaWatch;

  @override
  void initState() {
    super.initState();
    // Rulings and fresh contributor edits land while this queue is open;
    // the pending set must follow the table (audit 2026-09-04). Species
    // names follow theirs — an identification made in the inspector adds
    // a taxon this queue then has to name. Each watch emits once on
    // listen, so they are also the first loads.
    _pendingWatch = widget.db
        .changes({widget.db.reviewItems})
        .listen((_) => _loadPending());
    _taxaWatch = widget.db.changes({widget.db.taxa}).listen((_) => _loadTaxa());
  }

  @override
  void dispose() {
    _pendingWatch?.cancel();
    _taxaWatch?.cancel();
    _keys.dispose();
    super.dispose();
  }

  /// The reviewer's hands stay on the keys (design audit 2026-09-03):
  /// arrows walk the queue, A approves, R removes — acting on the
  /// selected record's pending item when there is one.
  Future<void> _onKey(KeyEvent e) async {
    if (e is! KeyDownEvent) return;
    final rows = _rows;
    if (rows.isEmpty) return;
    final i = rows.indexWhere((o) => o.id == _selectedId);
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _selectedId = rows[(i + 1).clamp(0, rows.length - 1)].id);
    } else if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _selectedId = rows[(i - 1).clamp(0, rows.length - 1)].id);
    } else if (e.logicalKey == LogicalKeyboardKey.keyA ||
        e.logicalKey == LogicalKeyboardKey.keyR) {
      final id = _selectedId;
      if (id == null) return;
      final item = await _review.forEntity('observation', id);
      if (item == null || !mounted) return;
      if (e.logicalKey == LogicalKeyboardKey.keyA) {
        if (item.state != 'pending') return;
        await _review.approve(item.id, by: 'owner');
      } else {
        if (item.state == 'removed') return;
        await _review.remove(item.id, by: 'owner');
      }
      // The ruling writes review_items; _pendingWatch reloads the queue.
    }
  }

  Future<void> _loadPending() async {
    final items = await _review.pending(widget.property.id);
    if (!mounted) return;
    setState(() {
      _pendingIds = {
        for (final i in items)
          if (i.entityType == 'observation') i.entityId,
      };
    });
  }

  Future<void> _loadTaxa() async {
    final taxa = await widget.db.select(widget.db.taxa).get();
    if (!mounted) return;
    setState(() {
      _taxonNames = {
        for (final t in taxa) t.id: t.commonName ?? t.scientificName,
      };
      _taxonNativity = {for (final t in taxa) t.id: t.nativity};
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = (widget.db.select(widget.db.observations)
      ..where((o) => o.propertyId.equals(widget.property.id))
      ..where((o) => o.deletedAt.isNull())
      ..orderBy([(o) => OrderingTerm.desc(o.observedAt)]));
    return KeyboardListener(
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Queue.
          SizedBox(
            width: 330,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(color: Press.borderInk, width: 1.5),
                ),
              ),
              child: StreamBuilder<List<Observation>>(
                stream: query.watch(),
                builder: (context, snapshot) {
                  final all = snapshot.data ?? [];
                  final obs = _pendingOnly
                      ? [
                          for (final o in all)
                            if (_pendingIds.contains(o.id)) o,
                        ]
                      : all;
                  _rows = obs;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(14, 12, 14, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Kicker('Queue'),
                            SizedBox(height: 4),
                            Row(
                              children: [
                                Text(
                                  _pendingOnly ? 'PENDING' : 'RECORDS',
                                  style: TextStyle(
                                    fontFamily: Type.slab,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 22,
                                    height: 0.9,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  '${obs.length}',
                                  style: TextStyle(
                                    fontFamily: Type.slab,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 22,
                                    color: Press.oxblood,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 8),
                            Row(
                              children: [
                                _QueueToggle(
                                  label: 'ALL',
                                  on: !_pendingOnly,
                                  onTap: () =>
                                      setState(() => _pendingOnly = false),
                                ),
                                SizedBox(width: 6),
                                _QueueToggle(
                                  label: 'PENDING ${_pendingIds.length}',
                                  on: _pendingOnly,
                                  onTap: () =>
                                      setState(() => _pendingOnly = true),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: obs.length,
                          itemBuilder: (context, i) {
                            final o = obs[i];
                            final selected = o.id == _selectedId;
                            return InkWell(
                              onTap: () => setState(() => _selectedId = o.id),
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: selected ? Press.paperRaised : null,
                                  border: Border(
                                    bottom: BorderSide(
                                      color: Press.divider,
                                      width: 1,
                                    ),
                                    left: BorderSide(
                                      color: selected
                                          ? Press.oxblood
                                          : Colors.transparent,
                                      width: 3,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Diamond(
                                      size: 9,
                                      color: recordTypeColor(o.observationType),
                                    ),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          MonoLabel(
                                            o.observationType,
                                            size: 8.5,
                                            spacing: 1.6,
                                            color: recordTypeColor(
                                              o.observationType,
                                            ),
                                          ),
                                          if (_taxonNames[o.taxonId] != null)
                                            Text(
                                              _taxonNames[o.taxonId]!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontFamily: Type.serif,
                                                fontSize: 14,
                                                color: Press.ink,
                                              ),
                                            ),
                                          if (_taxonNativity[o.taxonId] !=
                                                  null ||
                                              o.removalStatus != null)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 3,
                                              ),
                                              child: Wrap(
                                                spacing: 6,
                                                children: [
                                                  NativityChip(
                                                    _taxonNativity[o.taxonId],
                                                  ),
                                                  RemovalChip(
                                                    o.removalStatus,
                                                    removedOn: o.removedOn,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          MonoLabel(
                                            o.observedAt
                                                .replaceFirst('T', ' ')
                                                .substring(0, 16),
                                            size: 9,
                                            opacity: 0.7,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          // Inspector.
          Expanded(
            child: _selectedId == null
                ? Center(
                    child: MonoLabel(
                      '— select a record —',
                      size: 9.5,
                      spacing: 2,
                      opacity: 0.5,
                    ),
                  )
                : _Inspector(db: widget.db, obsId: _selectedId!),
          ),
        ],
      ),
    );
  }
}

class _QueueToggle extends StatelessWidget {
  const _QueueToggle({
    required this.label,
    required this.on,
    required this.onTap,
  });
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: on ? Press.ink : null,
          border: Border.all(color: Press.borderInk, width: 1),
        ),
        child: MonoLabel(
          label,
          size: 8.5,
          spacing: 1.4,
          color: on ? Press.paper : Press.ink,
        ),
      ),
    );
  }
}

/// The desk's record view: the facts, and the two things a desk is for
/// (D-024) — editing the record and ruling on a contributor's edit.
/// The desk's record view IS the phone's record screen (D-024: same
/// capabilities, minus the mobile affordances), with the steward's ruling
/// strip above it — approve or remove a contributor's edit.
class _Inspector extends StatefulWidget {
  _Inspector({required this.db, required this.obsId});
  final FieldNotesDb db;
  final String obsId;

  @override
  State<_Inspector> createState() => _InspectorState();
}

class _InspectorState extends State<_Inspector> {
  late final _review = ReviewService(widget.db);
  ReviewItem? _item;

  @override
  void initState() {
    super.initState();
    _loadItem();
  }

  @override
  void didUpdateWidget(covariant _Inspector old) {
    super.didUpdateWidget(old);
    if (old.obsId != widget.obsId) _loadItem();
  }

  Future<void> _loadItem() async {
    final item = await _review.forEntity('observation', widget.obsId);
    if (mounted) setState(() => _item = item);
  }

  Future<void> _approve(ReviewItem item) async {
    await _review.approve(item.id, by: 'owner');
    await _loadItem();
  }

  Future<void> _remove(ReviewItem item) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('REMOVE THIS EDIT?'),
        content: Text(
          'The record by ${item.author} will be removed for everyone. '
          'They will be able to see that it was removed — nothing '
          'vanishes silently.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('KEEP'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('REMOVE'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await _review.remove(item.id, by: 'owner');
    await _loadItem();
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final pending = item?.state == 'pending';
    return Column(
      children: [
        if (item != null)
          Container(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: pending ? Press.ochreLight : Press.paperEdge,
              border: Border(
                bottom: BorderSide(color: Press.borderInk, width: 1.5),
              ),
            ),
            child: Row(
              children: [
                StatusPill(
                  pending
                      ? 'PENDING · ${item.author}'
                      : '${item.state.toUpperCase()} · ${item.author}',
                  color: pending ? Press.ochre : Press.inkSoft,
                  filled: pending,
                ),
                Spacer(),
                if (pending)
                  SizedBox(
                    height: 36,
                    child: FilledButton(
                      onPressed: () => _approve(item),
                      child: Text('APPROVE'),
                    ),
                  ),
                if (item.state != 'removed') ...[
                  SizedBox(width: 8),
                  SizedBox(
                    height: 36,
                    child: OutlinedButton(
                      onPressed: () => _remove(item),
                      child: Text('REMOVE'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        Expanded(
          child: RecordDetailScreen(
            key: ValueKey(widget.obsId),
            db: widget.db,
            obsId: widget.obsId,
            embedded: true,
          ),
        ),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          alignment: Alignment.centerLeft,
          child: MonoLabel(
            'Edits made here stay on this computer until sync arrives (M4).',
            size: 8.5,
            opacity: 0.6,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────── Data & backup ───────────────────────────
