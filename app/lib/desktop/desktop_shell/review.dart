part of '../desktop_shell.dart';

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
  const _Inspector({required this.db, required this.obsId});
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
