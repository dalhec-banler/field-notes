import 'package:flutter/material.dart';

import '../db/database.dart';
import '../services/review.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';
import 'record_detail_screen.dart';

/// The steward's review feed (SYNC-DESIGN.md, pending-visible model):
/// every contributor edit awaiting a ruling, and the history of rulings.
/// Approve clears the tag everywhere; remove tombstones the edit — and
/// works on approved items too, because final say has no expiry.
///
/// Solo property: this screen is honestly empty and says why.
class ReviewFeedScreen extends StatefulWidget {
  const ReviewFeedScreen(
      {super.key, required this.db, required this.property});

  final FieldNotesDb db;
  final Property property;

  @override
  State<ReviewFeedScreen> createState() => _ReviewFeedScreenState();
}

class _ReviewFeedScreenState extends State<ReviewFeedScreen> {
  late final _service = ReviewService(widget.db);
  List<ReviewItem> _pending = const [];
  List<ReviewItem> _decided = const [];
  final Map<String, Observation> _observations = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pending = await _service.pending(widget.property.id);
    final decided = await _service.decided(widget.property.id);
    // Preview text for observation items — other entity types show their
    // type name until their detail views learn to preview here.
    for (final item in [...pending, ...decided]) {
      if (item.entityType == 'observation' &&
          !_observations.containsKey(item.entityId)) {
        final obs = await (widget.db.select(widget.db.observations)
              ..where((o) => o.id.equals(item.entityId)))
            .getSingleOrNull();
        if (obs != null) _observations[item.entityId] = obs;
      }
    }
    if (mounted) {
      setState(() {
        _pending = pending;
        _decided = decided;
      });
    }
  }

  Future<void> _approve(ReviewItem item) async {
    await _service.approve(item.id, by: 'owner');
    _load();
  }

  Future<void> _remove(ReviewItem item) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('REMOVE THIS EDIT?'),
        content: Text(
            'The ${item.entityType.replaceAll('_', ' ')} by ${item.author} '
            'will be removed for everyone. They will be able to see that it '
            'was removed — nothing vanishes silently.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('KEEP')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('REMOVE')),
        ],
      ),
    );
    if (sure != true) return;
    await _service.remove(item.id, by: 'owner');
    _load();
  }

  Widget _row(ReviewItem item, {required bool pending}) {
    final obs = _observations[item.entityId];
    final what = obs?.notes?.isNotEmpty == true
        ? obs!.notes!
        : item.entityType.replaceAll('_', ' ');
    return ListTile(
      minTileHeight: 64,
      onTap: obs == null
          ? null
          : () => Navigator.of(context)
              .push(MaterialPageRoute(
                  builder: (_) => RecordDetailScreen(
                      db: widget.db, obsId: obs.id)))
              .then((_) => _load()),
      leading: Diamond(
        size: 13,
        color: pending
            ? Press.ochre
            : item.state == 'approved'
                ? Press.sage
                : Press.oxblood,
        filled: true,
      ),
      title: Text(what,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontFamily: Type.serif, fontSize: 15.5)),
      subtitle: MonoLabel(
        pending
            ? '${item.author} · ${item.createdAt.substring(0, 10)}'
            : '${item.state} by ${item.decidedBy ?? '—'} · '
                '${(item.decidedAt ?? '').split('T').first}',
        size: 8.5,
        opacity: 0.75,
      ),
      trailing: pending
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Approve',
                icon: Icon(Icons.check, color: Press.sage),
                onPressed: () => _approve(item),
              ),
              IconButton(
                tooltip: 'Remove',
                icon: Icon(Icons.close, color: Press.oxblood),
                onPressed: () => _remove(item),
              ),
            ])
          : item.state == 'approved'
              ? IconButton(
                  tooltip: 'Remove anyway',
                  icon: Icon(Icons.visibility_off_outlined,
                      size: 20, color: Press.inkSoft),
                  onPressed: () => _remove(item),
                )
              : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Review')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.symmetric(vertical: 10),
          children: [
            if (_pending.isEmpty && _decided.isEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(
                    Metrics.gutter, 40, Metrics.gutter, 0),
                child: Text(
                  'Nothing to review. When this place is shared, edits from '
                  'other people land here wearing a pending tag — visible to '
                  'everyone from the moment they\'re made, but yours to '
                  'approve or remove. Even after approving, you can remove '
                  'an edit later. The steward\'s say is final, always.',
                  style: TextStyle(
                      fontFamily: Type.serif, fontSize: 15.5, height: 1.5),
                ),
              ),
            if (_pending.isNotEmpty) ...[
              Padding(
                padding: EdgeInsets.fromLTRB(Metrics.gutter, 4, 0, 4),
                child: MonoLabel('Awaiting your say · ${_pending.length}',
                    size: 9, spacing: 1.8),
              ),
              for (final item in _pending) _row(item, pending: true),
            ],
            if (_decided.isNotEmpty) ...[
              Padding(
                padding: EdgeInsets.fromLTRB(Metrics.gutter, 18, 0, 4),
                child: MonoLabel('Ruled on', size: 9, spacing: 1.8),
              ),
              for (final item in _decided) _row(item, pending: false),
            ],
          ],
        ),
      ),
    );
  }
}
