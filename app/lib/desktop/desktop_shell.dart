import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import '../main.dart' show exportAndShare;
import '../screens/backup_screen.dart';
import '../screens/drive_backup_screen.dart';
import '../screens/restore_screen.dart';
import '../services/app_prefs.dart';
import '../services/review.dart';
import '../services/survival.dart';
import '../widgets/edit_record_sheet.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';
import 'export_workspace.dart';
import 'receive_backup_panel.dart';

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

class _DesktopShellState extends State<DesktopShell> {
  int _view = 0;
  static const _views = [
    'Review',
    'Survival',
    'Propagation',
    'Export',
    'Data & backup',
  ];

  int _dbBytes = 0;
  int _mediaCount = 0;
  List<Property> _properties = const [];

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final docs = await getApplicationDocumentsDirectory();
    final dbFile = File(p.join(docs.path, 'field_notes.sqlite'));
    final media = await (widget.db.selectOnly(
      widget.db.media,
    )..addColumns([widget.db.media.id.count()])).getSingle();
    final properties =
        await (widget.db.select(widget.db.properties)
              ..where((p) => p.deletedAt.isNull())
              ..orderBy([(p) => OrderingTerm.asc(p.name)]))
            .get();
    if (mounted) {
      setState(() {
        _dbBytes = dbFile.existsSync() ? dbFile.lengthSync() : 0;
        _mediaCount = media.read(widget.db.media.id.count()) ?? 0;
        _properties = properties;
      });
    }
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
                        Expanded(child: _workspace()),
                        _statusBar(),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 14),
                _principleCells(),
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
              'database.sqlite · ${(_dbBytes / (1 << 20)).toStringAsFixed(1)} MB · $_mediaCount media',
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
              'Local only — no account · schema v1',
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

  Widget _workspace() {
    return switch (_view) {
      0 => _ReviewWorkspace(db: widget.db, property: widget.property),
      1 => _SurvivalWorkspace(db: widget.db, property: widget.property),
      2 => _PropagationWorkspace(db: widget.db, property: widget.property),
      3 => ExportWorkspace(db: widget.db, property: widget.property),
      _ => _DataWorkspace(
        db: widget.db,
        property: widget.property,
        prefs: widget.prefs,
      ),
    };
  }

  Widget _statusBar() {
    final sentences = [
      'Reviewing the local store · click a row to inspect',
      'Survival is derived at read time · never stored',
      'The chain must tolerate a break at either end',
      'A plate is the record drawn, not a new claim about it',
      'Nothing commits until you review the mapping',
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
          MonoLabel('Write queue empty | Sync off', size: 9.5, opacity: 0.8),
        ],
      ),
    );
  }

  Widget _principleCells() {
    final principles = [
      (
        'source of truth',
        'The phone is the source of truth. This desk reads '
            'a restored copy; it invents nothing.',
      ),
      (
        'permissions',
        'Roles are enforced in RLS as well as the UI. The '
            'greyed button is a courtesy, not the permission system.',
      ),
      (
        'suggestions',
        'Suggestions accumulate quietly. Nothing enters the '
            'record without acceptance.',
      ),
      (
        'numbers',
        'Nothing here is a new number — every figure derives from '
            'rows the field device wrote.',
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Press.borderInk, width: 1.5),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            for (var i = 0; i < principles.length; i++) ...[
              if (i > 0) Container(width: 1, color: Press.ink),
              Expanded(
                child: Container(
                  color: Press.paper,
                  padding: EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MonoLabel(
                        principles[i].$1,
                        size: 9,
                        spacing: 1.8,
                        color: Press.oxblood,
                      ),
                      SizedBox(height: 5),
                      Text(
                        principles[i].$2,
                        style: TextStyle(
                          fontFamily: Type.serif,
                          fontSize: 14.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
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
  bool _pendingOnly = false;
  Set<String> _pendingIds = const {};
  Map<String, String> _taxonNames = const {};
  late final _review = ReviewService(widget.db);

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  Future<void> _loadPending() async {
    final items = await _review.pending(widget.property.id);
    final taxa = await widget.db.select(widget.db.taxa).get();
    if (!mounted) return;
    setState(() {
      _pendingIds = {
        for (final i in items)
          if (i.entityType == 'observation') i.entityId,
      };
      _taxonNames = {
        for (final t in taxa) t.id: t.commonName ?? t.scientificName,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = (widget.db.select(widget.db.observations)
      ..where((o) => o.propertyId.equals(widget.property.id))
      ..where((o) => o.deletedAt.isNull())
      ..orderBy([(o) => OrderingTerm.desc(o.observedAt)]));
    return Row(
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
              : _Inspector(
                  db: widget.db,
                  obsId: _selectedId!,
                  onChanged: _loadPending,
                ),
        ),
      ],
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
class _Inspector extends StatefulWidget {
  _Inspector({required this.db, required this.obsId, this.onChanged});
  final FieldNotesDb db;
  final String obsId;
  final VoidCallback? onChanged;

  @override
  State<_Inspector> createState() => _InspectorState();
}

typedef _InspectorData = (Observation, TaxaData?, Zone?, String?, ReviewItem?);

class _InspectorState extends State<_Inspector> {
  late Future<_InspectorData> _future = _load();
  late final _review = ReviewService(widget.db);

  @override
  void didUpdateWidget(covariant _Inspector old) {
    super.didUpdateWidget(old);
    if (old.obsId != widget.obsId) _reload();
  }

  void _reload() {
    final next = _load();
    setState(() => _future = next);
    widget.onChanged?.call();
  }

  Future<_InspectorData> _load() async {
    final db = widget.db;
    final obsId = widget.obsId;
    final obs = await (db.select(
      db.observations,
    )..where((o) => o.id.equals(obsId))).getSingle();
    TaxaData? taxon;
    if (obs.taxonId != null) {
      taxon = await (db.select(
        db.taxa,
      )..where((t) => t.id.equals(obs.taxonId!))).getSingleOrNull();
    }
    Zone? zone;
    if (obs.zoneId != null) {
      zone = await (db.select(
        db.zones,
      )..where((z) => z.id.equals(obs.zoneId!))).getSingleOrNull();
    }
    String? photo;
    final link =
        await (db.select(db.mediaLinks)
              ..where(
                (l) =>
                    l.entityType.equals('observation') &
                    l.entityId.equals(obsId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (link != null) {
      final m = await (db.select(
        db.media,
      )..where((x) => x.id.equals(link.mediaId))).getSingleOrNull();
      if (m?.localPath != null && File(m!.localPath!).existsSync()) {
        photo = m.localPath;
      }
    }
    final item = await _review.forEntity('observation', obsId);
    return (obs, taxon, zone, photo, item);
  }

  Future<void> _edit(Observation obs, TaxaData? taxon) async {
    // No map on the desk yet: the pin moves on the phone.
    final outcome = await showEditRecordSheet(
      context,
      db: widget.db,
      obs: obs,
      taxon: taxon,
      allowMovePin: false,
    );
    if (outcome == EditOutcome.saved) _reload();
  }

  Future<void> _approve(ReviewItem item) async {
    await _review.approve(item.id, by: 'owner');
    _reload();
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
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_InspectorData>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Center(child: CircularProgressIndicator());
        }
        final (obs, taxon, zone, photo, item) = snapshot.data!;
        final pending = item?.state == 'pending';
        return ListView(
          padding: EdgeInsets.all(16),
          children: [
            Container(
              height: 216,
              decoration: BoxDecoration(
                color: Press.photoPlaceholder,
                border: Border.all(color: Press.borderInk, width: 1.5),
                image: photo != null
                    ? DecorationImage(
                        image: FileImage(File(photo)),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: Kicker(obs.observationType)),
                if (item != null)
                  StatusPill(
                    pending
                        ? 'PENDING · ${item.author}'
                        : item.state.toUpperCase(),
                    color: pending ? Press.ochre : Press.inkSoft,
                    filled: pending,
                  ),
              ],
            ),
            SizedBox(height: 6),
            taxon != null
                ? TaxonName(taxon.scientificName, size: 26)
                : Text(
                    obs.observationType.toUpperCase(),
                    style: TextStyle(
                      fontFamily: Type.slab,
                      fontWeight: FontWeight.w900,
                      fontSize: 22,
                    ),
                  ),
            SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Press.paperRaised,
                border: Border.all(color: Press.borderInk, width: 1.5),
              ),
              child: Column(
                children: [
                  FactRow(
                    'Observed',
                    obs.observedAt.replaceFirst('T', ' ').substring(0, 16),
                  ),
                  FactRow(
                    'Location',
                    '${obs.lat.toStringAsFixed(5)}, ${obs.lng.toStringAsFixed(5)}',
                  ),
                  FactRow('Zone', zone?.name ?? '—'),
                  FactRow(
                    'Sure?',
                    kConfidenceLabels[obs.taxonConfidence] ?? '—',
                  ),
                  FactRow('Notes', obs.notes ?? '—', last: true),
                ],
              ),
            ),
            SizedBox(height: 14),
            Row(
              children: [
                SizedBox(
                  height: 44,
                  child: FilledButton.icon(
                    icon: Icon(Icons.edit_outlined, size: 18),
                    label: Text('EDIT'),
                    onPressed: () => _edit(obs, taxon),
                  ),
                ),
                if (item != null) ...[
                  SizedBox(width: 8),
                  if (pending)
                    SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        onPressed: () => _approve(item),
                        child: Text('APPROVE'),
                      ),
                    ),
                  if (item.state != 'removed') ...[
                    SizedBox(width: 8),
                    SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        onPressed: () => _remove(item),
                        child: Text('REMOVE'),
                      ),
                    ),
                  ],
                ],
              ],
            ),
            SizedBox(height: 10),
            MonoLabel(
              'Edits made here stay on this computer until sync arrives (M4).',
              size: 8.5,
              opacity: 0.6,
            ),
          ],
        );
      },
    );
  }
}

// ──────────────────────────── Survival ────────────────────────────

class _SurvivalWorkspace extends StatelessWidget {
  _SurvivalWorkspace({required this.db, required this.property});
  final FieldNotesDb db;
  final Property property;

  Future<List<(PlantingEvent, TaxaData?, SurvivalResult?)>> _load() async {
    final events =
        await (db.select(db.plantingEvents)
              ..where((e) => e.propertyId.equals(property.id))
              ..where((e) => e.deletedAt.isNull())
              ..orderBy([(e) => OrderingTerm.desc(e.plantedOn)]))
            .get();
    final rows = <(PlantingEvent, TaxaData?, SurvivalResult?)>[];
    for (final e in events) {
      TaxaData? taxon;
      if (e.taxonId != null) {
        taxon = await (db.select(
          db.taxa,
        )..where((t) => t.id.equals(e.taxonId!))).getSingleOrNull();
      }
      rows.add((e, taxon, await survivalFor(db, e)));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<(PlantingEvent, TaxaData?, SurvivalResult?)>>(
      future: _load(),
      builder: (context, snapshot) {
        final rows = snapshot.data ?? [];
        final totalPlanted = rows.fold(0, (a, r) => a + r.$1.countPlanted);
        final totalAlive = rows.fold(0, (a, r) => a + (r.$3?.alive ?? 0));
        final weighted = totalPlanted == 0 ? 0.0 : totalAlive / totalPlanted;
        final under60 = rows
            .where((r) => r.$3 != null && r.$3!.rate < 0.6)
            .length;
        return ListView(
          padding: EdgeInsets.all(18),
          children: [
            StatCells(
              cells: [
                ('Alive', '$totalAlive / $totalPlanted', null),
                ('Weighted', (weighted * 100).toStringAsFixed(0), '%'),
                ('Under 60%', '$under60 of ${rows.length}', null),
              ],
            ),
            SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Press.borderInk, width: 1.5),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++)
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 13,
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
                          SizedBox(
                            width: 40,
                            child: MonoLabel(
                              '${i + 1}',
                              size: 10,
                              opacity: 0.6,
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TaxonName(
                                  rows[i].$2?.scientificName ?? 'Unknown',
                                  size: 17,
                                  maxLines: 1,
                                ),
                                MonoLabel(
                                  '${rows[i].$1.stockSource.replaceAll('_', ' ')}'
                                  '${rows[i].$1.batchId != null ? ' · lineage linked' : ''}',
                                  size: 8.5,
                                  opacity: 0.65,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 100,
                            child: MonoLabel(
                              rows[i].$1.plantedOn,
                              size: 9.5,
                              opacity: 0.75,
                            ),
                          ),
                          SizedBox(
                            width: 80,
                            child: MonoLabel(
                              rows[i].$3 == null
                                  ? '—'
                                  : '${rows[i].$3!.alive} / ${rows[i].$3!.total}',
                              size: 10,
                            ),
                          ),
                          SizedBox(
                            width: 160,
                            child: rows[i].$3 == null
                                ? MonoLabel(
                                    'no check-ins',
                                    size: 9,
                                    opacity: 0.5,
                                  )
                                : Row(
                                    children: [
                                      Expanded(
                                        child: Container(
                                          height: 9,
                                          decoration: BoxDecoration(
                                            color: Color(0x121B1813),
                                            border: Border.all(
                                              color: Press.ink,
                                              width: 1,
                                            ),
                                          ),
                                          child: FractionallySizedBox(
                                            alignment: Alignment.centerLeft,
                                            widthFactor: rows[i].$3!.rate.clamp(
                                              0.0,
                                              1.0,
                                            ),
                                            child: Container(
                                              color: survivalBandColor(
                                                rows[i].$3!.rate,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        '${(rows[i].$3!.rate * 100).toStringAsFixed(0)}%',
                                        style: TextStyle(
                                          fontFamily: Type.slab,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          color: survivalBandColor(
                                            rows[i].$3!.rate,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ],
                      ),
                    ),
                  if (rows.isEmpty)
                    Padding(
                      padding: EdgeInsets.all(24),
                      child: MonoLabel(
                        '— no plantings in the store —',
                        size: 9.5,
                        spacing: 2,
                        opacity: 0.5,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────── Propagation ───────────────────────────

class _PropagationWorkspace extends StatefulWidget {
  _PropagationWorkspace({required this.db, required this.property});
  final FieldNotesDb db;
  final Property property;

  @override
  State<_PropagationWorkspace> createState() => _PropagationWorkspaceState();
}

class _PropagationWorkspaceState extends State<_PropagationWorkspace> {
  String? _selectedBatchId;

  @override
  Widget build(BuildContext context) {
    final query = (widget.db.select(widget.db.propagationBatches)
      ..where((b) => b.propertyId.equals(widget.property.id))
      ..where((b) => b.deletedAt.isNull())
      ..orderBy([(b) => OrderingTerm.desc(b.startedOn)]));
    return StreamBuilder<List<PropagationBatche>>(
      stream: query.watch(),
      builder: (context, snapshot) {
        final batches = snapshot.data ?? [];
        final selected =
            batches.where((b) => b.id == _selectedBatchId).firstOrNull ??
            batches.firstOrNull;
        return Padding(
          padding: EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: kicker + batch table.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Kicker(
                      'source_plants → collection_events → propagation_batches → planting_events',
                    ),
                    SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Press.borderInk,
                            width: 1.5,
                          ),
                        ),
                        child: ListView(
                          children: [
                            for (final b in batches)
                              InkWell(
                                onTap: () =>
                                    setState(() => _selectedBatchId = b.id),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 13,
                                    vertical: 11,
                                  ),
                                  decoration: BoxDecoration(
                                    color: b.id == selected?.id
                                        ? Press.paperRaised
                                        : null,
                                    border: Border(
                                      bottom: BorderSide(
                                        color: Press.divider,
                                        width: 1,
                                      ),
                                      left: BorderSide(
                                        color: b.id == selected?.id
                                            ? Press.oxblood
                                            : Colors.transparent,
                                        width: 3,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Press.ink,
                                            width: 1.5,
                                          ),
                                        ),
                                        child: Text(
                                          b.batchCode ?? '—',
                                          style: TextStyle(
                                            fontFamily: Type.slab,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                      SizedBox(width: 10),
                                      Expanded(
                                        child: MonoLabel(
                                          '${b.method?.replaceAll('_', ' ') ?? ''} · started ${b.startedOn}',
                                          size: 9,
                                          opacity: 0.75,
                                        ),
                                      ),
                                      MonoLabel(
                                        '${b.countCurrent ?? b.countStarted ?? '?'}',
                                        size: 11,
                                      ),
                                      SizedBox(width: 10),
                                      StatusPill(
                                        b.status ?? 'active',
                                        color: switch (b.status) {
                                          'failed' => Press.oxblood,
                                          'planted_out' => Press.sage,
                                          'hardening' ||
                                          'rooted' => Press.ochre,
                                          _ => Press.inkSoft,
                                        },
                                        filled: b.status == 'failed',
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (batches.isEmpty)
                              Padding(
                                padding: EdgeInsets.all(24),
                                child: MonoLabel(
                                  '— no batches in the store —',
                                  size: 9.5,
                                  spacing: 2,
                                  opacity: 0.5,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 16),
              // Right: event log for the selected batch.
              SizedBox(
                width: 330,
                child: selected == null
                    ? SizedBox.shrink()
                    : _BatchEvents(db: widget.db, batch: selected),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BatchEvents extends StatelessWidget {
  _BatchEvents({required this.db, required this.batch});
  final FieldNotesDb db;
  final PropagationBatche batch;

  @override
  Widget build(BuildContext context) {
    final query = (db.select(db.batchEvents)
      ..where((e) => e.batchId.equals(batch.id))
      ..where((e) => e.deletedAt.isNull())
      ..orderBy([(e) => OrderingTerm.desc(e.occurredAt)]));
    return StreamBuilder<List<BatchEvent>>(
      stream: query.watch(),
      builder: (context, snapshot) {
        final events = snapshot.data ?? [];
        return Container(
          decoration: BoxDecoration(
            color: Press.paperRaised,
            border: Border.all(color: Press.borderInk, width: 1.5),
          ),
          padding: EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MonoLabel(
                'batch_events · ${batch.batchCode ?? ''}',
                size: 9,
                spacing: 1.8,
              ),
              SizedBox(height: 8),
              Expanded(
                child: events.isEmpty
                    ? MonoLabel(
                        '— quiet bench —',
                        size: 9,
                        spacing: 2,
                        opacity: 0.5,
                      )
                    : ListView(
                        children: [
                          for (final e in events)
                            Padding(
                              padding: EdgeInsets.only(bottom: 9),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  MonoLabel(
                                    '${e.occurredAt.substring(0, 10)} · ${e.eventType.replaceAll('_', ' ')}'
                                    '${e.countDelta != null ? ' (${e.countDelta! > 0 ? '+' : ''}${e.countDelta})' : ''}',
                                    size: 9,
                                    color: Press.oxblood,
                                  ),
                                  if (e.notes != null)
                                    Text(
                                      e.notes!,
                                      style: TextStyle(
                                        fontFamily: Type.serif,
                                        fontSize: 14,
                                        height: 1.4,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────── Data & backup ───────────────────────────

class _DataWorkspace extends StatelessWidget {
  _DataWorkspace({
    required this.db,
    required this.property,
    required this.prefs,
  });
  final FieldNotesDb db;
  final Property property;
  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        ReceiveBackupPanel(),
        _DataWorkspaceBody(db: db, property: property, prefs: prefs),
      ],
    );
  }
}

class _DataWorkspaceBody extends StatelessWidget {
  _DataWorkspaceBody({
    required this.db,
    required this.property,
    required this.prefs,
  });
  final FieldNotesDb db;
  final Property property;
  final AppPrefs prefs;

  @override
  Widget build(BuildContext context) {
    const tree = '''<property>-export-<date>/
  README.md
  database.sqlite
  data/
    observations.csv · plants.csv · plant_checkins.csv
    planting_events.csv · propagation_batches.csv
    features.csv · zones.csv · taxa.csv
  geo/
    observations.geojson · zones.geojson
    features.geojson · plantings.geojson · tracks.geojson
    property.kml
  media/photos/YYYY/MM/''';
    // A plain column: this sits inside the tab's ListView, and a nested
    // ListView has no height to give (it rendered nothing in release).
    return Padding(
      padding: EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  padding: EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Press.paperRaised,
                    border: Border.all(color: Press.borderInk, width: 1.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MonoLabel('Export all data', size: 9, spacing: 1.8),
                      const SizedBox(height: 8),
                      Text(
                        tree,
                        style: TextStyle(
                          fontFamily: Type.mono,
                          fontSize: 11.5,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 56,
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () =>
                              exportAndShare(context, db, property),
                          child: const Text('EXPORT ALL DATA'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Press.sage, width: 1.5),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            color: Press.sage,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Diamond(size: 9, color: Press.paper),
                                SizedBox(width: 7),
                                MonoLabel(
                                  'Encrypted backup',
                                  size: 10,
                                  spacing: 1.6,
                                  color: Press.paper,
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                Text(
                                  'Incremental and content-addressed. The '
                                  'weekly check decrypts the manifest and one '
                                  'blob and verifies the hash.',
                                  style: TextStyle(
                                    fontFamily: Type.serif,
                                    fontSize: 14.5,
                                    height: 1.45,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: SizedBox(
                                        height: 50,
                                        child: FilledButton(
                                          onPressed: () => Navigator.of(context)
                                              .push(
                                                MaterialPageRoute(
                                                  builder: (_) => BackupScreen(
                                                    db: db,
                                                    prefs: prefs,
                                                  ),
                                                ),
                                              ),
                                          child: const Text('BACKUP'),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: SizedBox(
                                        height: 50,
                                        child: OutlinedButton(
                                          onPressed: () => Navigator.of(context)
                                              .push(
                                                MaterialPageRoute(
                                                  builder: (_) =>
                                                      const RestoreScreen(),
                                                ),
                                              ),
                                          child: const Text('RESTORE'),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Press.paperRaised,
                        border: Border.all(color: Press.borderInk, width: 1.5),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                MonoLabel(
                                  'Google Drive',
                                  size: 9,
                                  spacing: 1.8,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'The same hidden app folder the phone backs '
                                  'up to. Back up this desk there, verify it, '
                                  'or restore from it.',
                                  style: TextStyle(
                                    fontFamily: Type.serif,
                                    fontSize: 14,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 44,
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      DriveBackupScreen(db: db, prefs: prefs),
                                ),
                              ),
                              child: const Text('OPEN DRIVE'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    RailNote(
                      color: Press.sage,
                      label: 'restore · database first, media after',
                      body:
                          'Bring a backup zip from the phone: the database '
                          'restores in seconds and this desk is immediately '
                          'usable; media streams in behind it.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
