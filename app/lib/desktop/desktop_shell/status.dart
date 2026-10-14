part of '../desktop_shell.dart';

/// Sync, Drive and the status bar: what the shell says about the state
/// of the record.
mixin _DesktopShellStatus on _DesktopShellCore {
  Future<void> _autoSync() async {
    final log = opLog;
    if (log == null) return;
    final r = await SyncService(widget.db, widget.prefs, log)
        .maybeRunAutomatic()
        .catchError((Object e, StackTrace st) {
          Diag.report(e, st, where: 'DesktopShell._autoSync');
          return null;
        });
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

  /// Writes captured by the oplog and not yet carried anywhere.
  Future<int> _pendingWrites() async {
    try {
      final row = await widget.db
          .customSelect('SELECT COUNT(*) AS n FROM sync_ops')
          .getSingleOrNull();
      return (row?.data['n'] as int?) ?? 0;
    } catch (e, st) {
      Diag.report(e, st, where: 'DesktopShell._pendingWrites');
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
