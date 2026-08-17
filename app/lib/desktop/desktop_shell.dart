import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import '../main.dart' show exportAndShare;
import '../screens/backup_screen.dart';
import '../screens/restore_screen.dart';
import '../services/survival.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Desk companion (design README §4): a single window shell — title bar,
/// nav, workspace, status bar, principle cells. The phone is the source of
/// truth; data arrives here by restore-from-zip.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  int _view = 0;
  static const _views = ['Review', 'Survival', 'Propagation', 'Data & backup'];

  int _dbBytes = 0;
  int _mediaCount = 0;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final docs = await getApplicationDocumentsDirectory();
    final dbFile = File(p.join(docs.path, 'field_notes.sqlite'));
    final media = await (widget.db.selectOnly(widget.db.media)
          ..addColumns([widget.db.media.id.count()]))
        .getSingle();
    if (mounted) {
      setState(() {
        _dbBytes = dbFile.existsSync() ? dbFile.lengthSync() : 0;
        _mediaCount = media.read(widget.db.media.id.count()) ?? 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Press.paperEdge,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1400),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Press.paper,
                      border: Border.all(color: Press.ink, width: 1.5),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x6B14120C),
                            offset: Offset(0, 34),
                            blurRadius: 60,
                            spreadRadius: -26),
                        BoxShadow(
                            color: Color(0x3814120C),
                            offset: Offset(0, 10),
                            blurRadius: 22,
                            spreadRadius: -14),
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
                const SizedBox(height: 14),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Opacity(
                  opacity: 0.5,
                  child: Diamond(size: 7, color: Press.paper)),
            ),
          const SizedBox(width: 8),
          MonoLabel('Field Station · ${widget.property.name}',
              size: 10.5, spacing: 1.6, color: Press.paper),
          const SizedBox(width: 16),
          MonoLabel(
              'database.sqlite · ${(_dbBytes / (1 << 20)).toStringAsFixed(1)} MB · $_mediaCount media',
              size: 9.5,
              color: Press.paper,
              opacity: 0.72),
          const Spacer(),
          const Diamond(size: 8, color: Press.sage, blink: true),
          const SizedBox(width: 6),
          const MonoLabel('Local only — no account · schema v1',
              size: 9.5, color: Press.paper, opacity: 0.9),
        ],
      ),
    );
  }

  Widget _navBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Press.paperEdge,
        border: Border(bottom: BorderSide(color: Press.ink, width: 2)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _views.length; i++)
            InkWell(
              onTap: () => setState(() => _view = i),
              child: Container(
                constraints: const BoxConstraints(minHeight: 50),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: i == _view ? Press.paper : null,
                  border: const Border(
                      right: BorderSide(color: Color(0x331B1813), width: 1)),
                  boxShadow: i == _view
                      ? const [
                          BoxShadow(
                              color: Press.oxblood,
                              offset: Offset(0, -3),
                              blurRadius: 0,
                              spreadRadius: -18)
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
                              : Press.inkSoft.withValues(alpha: 0.4)),
                      const SizedBox(width: 7),
                      MonoLabel(_views[i],
                          size: 10, spacing: 1.6, color: Press.ink),
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
      _ => _DataWorkspace(db: widget.db, property: widget.property),
    };
  }

  Widget _statusBar() {
    const sentences = [
      'Reviewing the local store · click a row to inspect',
      'Survival is derived at read time · never stored',
      'The chain must tolerate a break at either end',
      'Nothing commits until you review the mapping',
    ];
    return Container(
      decoration: const BoxDecoration(
        color: Press.paperEdge,
        border: Border(top: BorderSide(color: Press.ink, width: 2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        children: [
          MonoLabel(sentences[_view], size: 9.5, opacity: 0.8),
          const Spacer(),
          const MonoLabel('Write queue empty | Sync off',
              size: 9.5, opacity: 0.8),
        ],
      ),
    );
  }

  Widget _principleCells() {
    const principles = [
      ('source of truth', 'The phone is the source of truth. This desk reads '
          'a restored copy; it invents nothing.'),
      ('permissions', 'Roles are enforced in RLS as well as the UI. The '
          'greyed button is a courtesy, not the permission system.'),
      ('suggestions', 'Suggestions accumulate quietly. Nothing enters the '
          'record without acceptance.'),
      ('numbers', 'Nothing here is a new number — every figure derives from '
          'rows the field device wrote.'),
    ];
    return Container(
      decoration: BoxDecoration(border: Border.all(color: Press.ink, width: 1.5)),
      child: IntrinsicHeight(
        child: Row(
          children: [
            for (var i = 0; i < principles.length; i++) ...[
              if (i > 0) Container(width: 1, color: Press.ink),
              Expanded(
                child: Container(
                  color: Press.paper,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MonoLabel(principles[i].$1,
                          size: 9, spacing: 1.8, color: Press.oxblood),
                      const SizedBox(height: 5),
                      Text(principles[i].$2,
                          style: const TextStyle(
                              fontFamily: Type.serif,
                              fontSize: 14.5,
                              height: 1.4)),
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
  const _ReviewWorkspace({required this.db, required this.property});
  final FieldNotesDb db;
  final Property property;

  @override
  State<_ReviewWorkspace> createState() => _ReviewWorkspaceState();
}

class _ReviewWorkspaceState extends State<_ReviewWorkspace> {
  String? _selectedId;

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
            decoration: const BoxDecoration(
              border:
                  Border(right: BorderSide(color: Press.ink, width: 1.5)),
            ),
            child: StreamBuilder<List<Observation>>(
              stream: query.watch(),
              builder: (context, snapshot) {
                final obs = snapshot.data ?? const [];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Kicker('Queue'),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Text('NEEDS A LOOK',
                                  style: TextStyle(
                                      fontFamily: Type.slab,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 22,
                                      height: 0.9)),
                              const SizedBox(width: 8),
                              Text('${obs.length}',
                                  style: const TextStyle(
                                      fontFamily: Type.slab,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 22,
                                      color: Press.oxblood)),
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
                            onTap: () =>
                                setState(() => _selectedId = o.id),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color:
                                    selected ? Press.paperRaised : null,
                                border: Border(
                                  bottom: const BorderSide(
                                      color: Press.divider, width: 1),
                                  left: BorderSide(
                                      color: selected
                                          ? Press.oxblood
                                          : Colors.transparent,
                                      width: 3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Diamond(
                                      size: 9,
                                      color: recordTypeColor(
                                          o.observationType)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        MonoLabel(o.observationType,
                                            size: 8.5,
                                            spacing: 1.6,
                                            color: recordTypeColor(
                                                o.observationType)),
                                        MonoLabel(
                                            o.observedAt
                                                .replaceFirst('T', ' ')
                                                .substring(0, 16),
                                            size: 9,
                                            opacity: 0.7),
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
              ? const Center(
                  child: MonoLabel('— select a record —',
                      size: 9.5, spacing: 2, opacity: 0.5))
              : _Inspector(db: widget.db, obsId: _selectedId!),
        ),
      ],
    );
  }
}

class _Inspector extends StatelessWidget {
  const _Inspector({required this.db, required this.obsId});
  final FieldNotesDb db;
  final String obsId;

  Future<(Observation, TaxaData?, Zone?, String?)> _load() async {
    final obs = await (db.select(db.observations)
          ..where((o) => o.id.equals(obsId)))
        .getSingle();
    TaxaData? taxon;
    if (obs.taxonId != null) {
      taxon = await (db.select(db.taxa)
            ..where((t) => t.id.equals(obs.taxonId!)))
          .getSingleOrNull();
    }
    Zone? zone;
    if (obs.zoneId != null) {
      zone = await (db.select(db.zones)
            ..where((z) => z.id.equals(obs.zoneId!)))
          .getSingleOrNull();
    }
    String? photo;
    final link = await (db.select(db.mediaLinks)
          ..where((l) =>
              l.entityType.equals('observation') & l.entityId.equals(obsId))
          ..limit(1))
        .getSingleOrNull();
    if (link != null) {
      final m = await (db.select(db.media)
            ..where((x) => x.id.equals(link.mediaId)))
          .getSingleOrNull();
      if (m?.localPath != null && File(m!.localPath!).existsSync()) {
        photo = m.localPath;
      }
    }
    return (obs, taxon, zone, photo);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(Observation, TaxaData?, Zone?, String?)>(
      key: ValueKey(obsId),
      future: _load(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (obs, taxon, zone, photo) = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              height: 216,
              decoration: BoxDecoration(
                color: Press.photoPlaceholder,
                border: Border.all(color: Press.ink, width: 1.5),
                image: photo != null
                    ? DecorationImage(
                        image: FileImage(File(photo)), fit: BoxFit.cover)
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            Kicker(obs.observationType),
            const SizedBox(height: 6),
            taxon != null
                ? TaxonName(taxon.scientificName, size: 26)
                : Text(obs.observationType.toUpperCase(),
                    style: const TextStyle(
                        fontFamily: Type.slab,
                        fontWeight: FontWeight.w900,
                        fontSize: 22)),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Press.paperRaised,
                border: Border.all(color: Press.ink, width: 1.5),
              ),
              child: Column(
                children: [
                  FactRow('observed_at',
                      obs.observedAt.replaceFirst('T', ' ').substring(0, 16)),
                  FactRow('lat / lng',
                      '${obs.lat.toStringAsFixed(5)}, ${obs.lng.toStringAsFixed(5)}'),
                  FactRow('zone_id', zone?.name ?? '—'),
                  FactRow('notes', obs.notes ?? '—', last: true),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ──────────────────────────── Survival ────────────────────────────

class _SurvivalWorkspace extends StatelessWidget {
  const _SurvivalWorkspace({required this.db, required this.property});
  final FieldNotesDb db;
  final Property property;

  Future<List<(PlantingEvent, TaxaData?, SurvivalResult?)>> _load() async {
    final events = await (db.select(db.plantingEvents)
          ..where((e) => e.propertyId.equals(property.id))
          ..where((e) => e.deletedAt.isNull())
          ..orderBy([(e) => OrderingTerm.desc(e.plantedOn)]))
        .get();
    final rows = <(PlantingEvent, TaxaData?, SurvivalResult?)>[];
    for (final e in events) {
      TaxaData? taxon;
      if (e.taxonId != null) {
        taxon = await (db.select(db.taxa)
              ..where((t) => t.id.equals(e.taxonId!)))
            .getSingleOrNull();
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
        final rows = snapshot.data ?? const [];
        final totalPlanted =
            rows.fold(0, (a, r) => a + r.$1.countPlanted);
        final totalAlive = rows.fold(0, (a, r) => a + (r.$3?.alive ?? 0));
        final weighted =
            totalPlanted == 0 ? 0.0 : totalAlive / totalPlanted;
        final under60 = rows
            .where((r) => r.$3 != null && r.$3!.rate < 0.6)
            .length;
        return ListView(
          padding: const EdgeInsets.all(18),
          children: [
            StatCells(cells: [
              ('Alive', '$totalAlive / $totalPlanted', null),
              ('Weighted', (weighted * 100).toStringAsFixed(0), '%'),
              ('Under 60%', '$under60 of ${rows.length}', null),
            ]),
            const SizedBox(height: 16),
            Container(
              decoration:
                  BoxDecoration(border: Border.all(color: Press.ink, width: 1.5)),
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 13),
                      decoration: BoxDecoration(
                        color: Press.paperRaised,
                        border: i < rows.length - 1
                            ? const Border(
                                bottom: BorderSide(
                                    color: Press.divider, width: 1))
                            : null,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: MonoLabel('${i + 1}',
                                size: 10, opacity: 0.6),
                          ),
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TaxonName(
                                    rows[i].$2?.scientificName ?? 'Unknown',
                                    size: 17,
                                    maxLines: 1),
                                MonoLabel(
                                    '${rows[i].$1.stockSource.replaceAll('_', ' ')}'
                                    '${rows[i].$1.batchId != null ? ' · lineage linked' : ''}',
                                    size: 8.5,
                                    opacity: 0.65),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 100,
                            child: MonoLabel(rows[i].$1.plantedOn,
                                size: 9.5, opacity: 0.75),
                          ),
                          SizedBox(
                            width: 80,
                            child: MonoLabel(
                                rows[i].$3 == null
                                    ? '—'
                                    : '${rows[i].$3!.alive} / ${rows[i].$3!.total}',
                                size: 10),
                          ),
                          SizedBox(
                            width: 160,
                            child: rows[i].$3 == null
                                ? const MonoLabel('no check-ins',
                                    size: 9, opacity: 0.5)
                                : Row(
                                    children: [
                                      Expanded(
                                        child: Container(
                                          height: 9,
                                          decoration: BoxDecoration(
                                            color: const Color(0x121B1813),
                                            border: Border.all(
                                                color: Press.ink, width: 1),
                                          ),
                                          child: FractionallySizedBox(
                                            alignment: Alignment.centerLeft,
                                            widthFactor: rows[i]
                                                .$3!
                                                .rate
                                                .clamp(0.0, 1.0),
                                            child: Container(
                                                color: survivalBandColor(
                                                    rows[i].$3!.rate)),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '${(rows[i].$3!.rate * 100).toStringAsFixed(0)}%',
                                        style: TextStyle(
                                          fontFamily: Type.slab,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          color: survivalBandColor(
                                              rows[i].$3!.rate),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ],
                      ),
                    ),
                  if (rows.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: MonoLabel('— no plantings in the store —',
                          size: 9.5, spacing: 2, opacity: 0.5),
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
  const _PropagationWorkspace({required this.db, required this.property});
  final FieldNotesDb db;
  final Property property;

  @override
  State<_PropagationWorkspace> createState() =>
      _PropagationWorkspaceState();
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
        final batches = snapshot.data ?? const [];
        final selected = batches
                .where((b) => b.id == _selectedBatchId)
                .firstOrNull ??
            batches.firstOrNull;
        return Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: kicker + batch table.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Kicker(
                        'source_plants → collection_events → propagation_batches → planting_events'),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                            border:
                                Border.all(color: Press.ink, width: 1.5)),
                        child: ListView(
                          children: [
                            for (final b in batches)
                              InkWell(
                                onTap: () => setState(
                                    () => _selectedBatchId = b.id),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 13, vertical: 11),
                                  decoration: BoxDecoration(
                                    color: b.id == selected?.id
                                        ? Press.paperRaised
                                        : null,
                                    border: Border(
                                      bottom: const BorderSide(
                                          color: Press.divider, width: 1),
                                      left: BorderSide(
                                          color: b.id == selected?.id
                                              ? Press.oxblood
                                              : Colors.transparent,
                                          width: 3),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets
                                            .symmetric(
                                            horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                            border: Border.all(
                                                color: Press.ink,
                                                width: 1.5)),
                                        child: Text(
                                          b.batchCode ?? '—',
                                          style: const TextStyle(
                                              fontFamily: Type.slab,
                                              fontWeight: FontWeight.w900,
                                              fontSize: 14),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: MonoLabel(
                                            '${b.method?.replaceAll('_', ' ') ?? ''} · started ${b.startedOn}',
                                            size: 9,
                                            opacity: 0.75),
                                      ),
                                      MonoLabel(
                                          '${b.countCurrent ?? b.countStarted ?? '?'}',
                                          size: 11),
                                      const SizedBox(width: 10),
                                      StatusPill(
                                        b.status ?? 'active',
                                        color: switch (b.status) {
                                          'failed' => Press.oxblood,
                                          'planted_out' => Press.sage,
                                          'hardening' ||
                                          'rooted' =>
                                            Press.ochre,
                                          _ => Press.inkSoft,
                                        },
                                        filled: b.status == 'failed',
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            if (batches.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(24),
                                child: MonoLabel(
                                    '— no batches in the store —',
                                    size: 9.5,
                                    spacing: 2,
                                    opacity: 0.5),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Right: event log for the selected batch.
              SizedBox(
                width: 330,
                child: selected == null
                    ? const SizedBox.shrink()
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
  const _BatchEvents({required this.db, required this.batch});
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
        final events = snapshot.data ?? const [];
        return Container(
          decoration: BoxDecoration(
            color: Press.paperRaised,
            border: Border.all(color: Press.ink, width: 1.5),
          ),
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MonoLabel('batch_events · ${batch.batchCode ?? ''}',
                  size: 9, spacing: 1.8),
              const SizedBox(height: 8),
              Expanded(
                child: events.isEmpty
                    ? const MonoLabel('— quiet bench —',
                        size: 9, spacing: 2, opacity: 0.5)
                    : ListView(
                        children: [
                          for (final e in events)
                            Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 9),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  MonoLabel(
                                      '${e.occurredAt.substring(0, 10)} · ${e.eventType.replaceAll('_', ' ')}'
                                      '${e.countDelta != null ? ' (${e.countDelta! > 0 ? '+' : ''}${e.countDelta})' : ''}',
                                      size: 9,
                                      color: Press.oxblood),
                                  if (e.notes != null)
                                    Text(e.notes!,
                                        style: const TextStyle(
                                            fontFamily: Type.serif,
                                            fontSize: 14,
                                            height: 1.4)),
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
  const _DataWorkspace({required this.db, required this.property});
  final FieldNotesDb db;
  final Property property;

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
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Press.paperRaised,
                  border: Border.all(color: Press.ink, width: 1.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MonoLabel('Take it all', size: 9, spacing: 1.8),
                    const SizedBox(height: 8),
                    const Text(tree,
                        style: TextStyle(
                            fontFamily: Type.mono,
                            fontSize: 11.5,
                            height: 1.5)),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 56,
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () =>
                            exportAndShare(context, db, property),
                        child: const Text('TAKE MY DATA'),
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
                        border:
                            Border.all(color: Press.sage, width: 1.5)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          color: Press.sage,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: const Row(
                            children: [
                              Diamond(size: 9, color: Press.paper),
                              SizedBox(width: 7),
                              MonoLabel('Encrypted backup',
                                  size: 10,
                                  spacing: 1.6,
                                  color: Press.paper),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              const Text(
                                'Incremental and content-addressed. The '
                                'weekly check decrypts the manifest and one '
                                'blob and verifies the hash.',
                                style: TextStyle(
                                    fontFamily: Type.serif,
                                    fontSize: 14.5,
                                    height: 1.45),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      height: 50,
                                      child: FilledButton(
                                        onPressed: () => Navigator.of(
                                                context)
                                            .push(MaterialPageRoute(
                                                builder: (_) =>
                                                    BackupScreen(db: db))),
                                        child: const Text('BACKUP'),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: SizedBox(
                                      height: 50,
                                      child: OutlinedButton(
                                        onPressed: () => Navigator.of(
                                                context)
                                            .push(MaterialPageRoute(
                                                builder: (_) =>
                                                    const RestoreScreen())),
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
                  const RailNote(
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
    );
  }
}
