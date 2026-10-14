import 'dart:async';

import 'package:flutter/material.dart';

import '../backup/drive_auth.dart';
import '../db/database.dart';
import '../main.dart' show opLog;
import '../services/app_prefs.dart';
import '../services/desk.dart';
import '../sync/conflict_log.dart';
import '../sync/oplog.dart';
import '../sync/sync_service.dart';
import '../sync/sync_status.dart';
import '../theme/tokens.dart';
import '../widgets/passphrase_dialog.dart';
import '../widgets/press.dart';
import 'backup_screen.dart';
import 'drive_backup_screen.dart';

/// Sync with Drive (D-028): the phone and the desk exchange edits through
/// the same hidden Drive folder the backup uses, sealed with the same
/// keyring. This screen is the one place that runs it by hand, connects
/// the account, and says what happened.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.db, required this.prefs});
  final FieldNotesDb db;
  final AppPrefs prefs;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  SyncService? _service;
  OpLog? _log;
  String? _lastNote;
  int _mediaMissing = 0;
  bool _busy = false;
  String? _status;
  bool _hasProperty = true;

  /// Live: recomputed on every captured write and every sync run.
  SyncStatus? _syncStatus;
  StreamSubscription<SyncStatus>? _statusSub;
  List<SyncConflict> _conflicts = const [];
  StreamSubscription<void>? _conflictSub;

  @override
  void initState() {
    super.initState();
    final log = opLog;
    _log = log;
    if (log != null) {
      _service = SyncService(widget.db, widget.prefs, log);
      _statusSub = SyncStatus.watch(widget.db, log).listen((s) {
        if (mounted) setState(() => _syncStatus = s);
      });
      _conflictSub = log.conflicts.changes.listen((_) => _loadConflicts());
      _loadConflicts();
    }
    _load();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _conflictSub?.cancel();
    super.dispose();
  }

  Future<void> _loadConflicts() async {
    final log = _log;
    if (log == null) return;
    final list = await log.conflicts.read();
    if (mounted) setState(() => _conflicts = list);
  }

  Future<void> _load() async {
    final s = _service;
    final props = await (widget.db.select(
      widget.db.properties,
    )..where((p) => p.deletedAt.isNull())).get();
    if (s == null) {
      if (mounted) setState(() => _hasProperty = props.isNotEmpty);
      return;
    }
    final note = await s.lastNote;
    final missing = await s.mediaMissing;
    if (!mounted) return;
    setState(() {
      _lastNote = note;
      _mediaMissing = missing;
      _hasProperty = props.isNotEmpty;
    });
  }

  Future<void> _connect() async {
    setState(() => _status = 'Connecting…');
    final token = await DriveAuth.instance.accessToken(interactive: true);
    if (token != null) {
      widget.prefs.driveEmail = DriveAuth.instance.lastKnownEmail;
    }
    if (mounted) {
      setState(() => _status = token == null ? 'Not connected.' : null);
    }
  }

  Future<void> _run() async {
    final s = _service;
    if (s == null) return;
    setState(() {
      _busy = true;
      _status = 'Starting…';
    });
    final r = await s.sync(
      interactive: true,
      askPassphrase: () => askPassphraseDialog(context),
      onStatus: (t) => mounted ? setState(() => _status = t) : null,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = r.summary;
    });
    _load();
  }

  /// The one reason a sync can fail that a button here can't fix: the
  /// phone's Drive copy is plain (D-010), and sync is sealed-only (D-026).
  bool get _needsPassphraseSetup =>
      (_status ?? _lastNote ?? '').contains('to be encrypted');

  String _ago(DateTime? t) => t == null ? 'never' : SyncStatus.ago(t);

  /// A device id as a person reads it: this one by name, a peer by its
  /// first eight characters.
  String _who(String device) {
    if (device.isEmpty) return 'an older copy';
    if (device == _log?.deviceId) return isDesk ? 'this desk' : 'this phone';
    return device.length > 8 ? device.substring(0, 8) : device;
  }

  Widget _conflictsSection() {
    final log = _log;
    if (log == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: MonoLabel(
                'CONFLICTS',
                size: 9,
                spacing: 1.8,
                color: Press.oxblood,
              ),
            ),
            if (_conflicts.isNotEmpty)
              TextButton(
                onPressed: () => log.conflicts.clear(),
                child: const Text('CLEAR'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _conflicts.isEmpty
              ? 'None. When two devices change the same record before they '
                    'have synced, the later change stands and the other is '
                    'listed here.'
              : 'Two devices changed the same record before they had synced. '
                    'The later change stands; nothing is lost from the log.',
          style: TextStyle(
            fontFamily: Type.serif,
            fontSize: 14,
            height: 1.4,
            color: Press.inkSoft,
          ),
        ),
        if (_conflicts.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Press.paperRaised,
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _conflicts.length; i++)
                  _conflictRow(_conflicts[i], last: i == _conflicts.length - 1),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _conflictRow(SyncConflict c, {required bool last}) {
    final what = c.kept
        ? '${_who(c.winner)} kept its version; ${_who(c.loser)}\'s was set aside'
        : '${_who(c.winner)}\'s version replaced an unsent change on '
              '${_who(c.loser)}';
    final fields = c.fields.isEmpty ? '' : ' · ${c.fields.join(', ')}';
    final table = c.table.replaceAll('_', ' ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: Press.divider, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MonoLabel(
            '${SyncStatus.ago(c.at).toUpperCase()} · $table$fields',
            size: 9,
            spacing: 1.2,
            opacity: 0.65,
          ),
          const SizedBox(height: 3),
          Text(
            what,
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 14,
              height: 1.35,
              color: Press.ink,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.prefs.driveEmail != null;
    final unavailable = _service == null;
    final st = _syncStatus;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync with Drive')),
      body: ListView(
        padding: EdgeInsets.all(Metrics.gutter),
        children: [
          Text(
            isDesk
                ? 'Edits made here reach the phone, and the phone\'s reach '
                      'here, through the hidden Drive folder the backup '
                      'already uses. Everything is sealed before it leaves; '
                      'Google holds ciphertext. Photos travel on Wi-Fi.'
                : 'Edits made on the desk reach this phone, and yours reach '
                      'the desk, through the hidden Drive folder the backup '
                      'already uses. Everything is sealed before it leaves; '
                      'Google holds ciphertext. Photos wait for Wi-Fi unless '
                      'you allow cellular.',
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 15.5,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Press.paperRaised,
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (st != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                    child: Text(
                      st.line(),
                      style: TextStyle(
                        fontFamily: Type.serif,
                        fontSize: 15,
                        height: 1.4,
                        color: st.lastAttemptFailed
                            ? Press.oxblood
                            : Press.ink,
                      ),
                    ),
                  ),
                FactRow('Account', widget.prefs.driveEmail ?? 'Not connected'),
                FactRow('Last synced', _ago(st?.lastSuccessAt)),
                if (st?.lastAttemptAt != null &&
                    st!.lastAttemptAt != st.lastSuccessAt)
                  FactRow('Last tried', _ago(st.lastAttemptAt)),
                FactRow(
                  'Waiting to send',
                  (st?.pending ?? 0) == 0
                      ? 'nothing'
                      : '${st!.pending} change${st.pending == 1 ? '' : 's'}',
                ),
                if ((st?.receivedLastRun ?? 0) > 0)
                  FactRow('Last run brought', '${st!.receivedLastRun} changes'),
                if (st != null && st.peers.isNotEmpty)
                  FactRow(
                    'Heard from',
                    st.peers.map(_who).join(', '),
                  ),
                if (_mediaMissing > 0)
                  FactRow('Photos to fetch', '$_mediaMissing'),
                if (st?.lastFailure != null)
                  FactRow(
                    'Last problem',
                    '${st!.lastFailure} '
                        '(${_ago(st.lastFailureAt)})',
                  ),
                if (_lastNote != null) FactRow('Last result', _lastNote!),
              ],
            ),
          ),
          if (unavailable) ...[
            const SizedBox(height: 12),
            RailNote(
              color: Press.oxblood,
              body:
                  'Change capture did not start with the app, so there is '
                  'nothing to sync. Restart Field Notes.',
            ),
          ],
          const SizedBox(height: 14),
          if (!connected)
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: _busy ? null : _connect,
                child: const Text('CONNECT GOOGLE DRIVE'),
              ),
            )
          else
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                icon: const Icon(Icons.sync),
                label: Text(_busy ? 'SYNCING…' : 'SYNC NOW'),
                onPressed: _busy || unavailable ? null : _run,
              ),
            ),
          if (_status != null) ...[
            const SizedBox(height: 10),
            MonoLabel(_status!, size: 10, spacing: 1.2),
          ],
          if (_needsPassphraseSetup) ...[
            const SizedBox(height: 14),
            RailNote(
              color: Press.oxblood,
              body: isDesk
                  ? 'The phone\'s Drive backup is unencrypted (convenience '
                        'mode), and sync never writes to Drive in the clear. '
                        'On the phone: Settings → BACK UP NOW → switch on '
                        '"Encrypt with a passphrase" → back up → BACK UP TO '
                        'GOOGLE DRIVE. Then sync here with that passphrase.'
                  : 'Your Drive backup is unencrypted (convenience mode), '
                        'and sync never writes to Drive in the clear. Set a '
                        'passphrase under Backup, back up to Drive once, and '
                        'sync works on both devices.',
            ),
            if (!isDesk) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context)
                      .push(
                        MaterialPageRoute(
                          builder: (_) =>
                              BackupScreen(db: widget.db, prefs: widget.prefs),
                        ),
                      )
                      .then((_) => _load()),
                  child: const Text('SET A PASSPHRASE UNDER BACKUP'),
                ),
              ),
            ],
          ],
          const SizedBox(height: 14),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sync automatically'),
            subtitle: Text(
              isDesk
                  ? 'when this app opens, comes back, and every few minutes'
                  : 'when the app opens and comes back to the front',
            ),
            value: widget.prefs.driveSync,
            onChanged: (v) => setState(() => widget.prefs.driveSync = v),
          ),
          const SizedBox(height: 18),
          _conflictsSection(),
          if (isDesk && !_hasProperty) ...[
            const SizedBox(height: 14),
            RailNote(
              color: Press.sage,
              body:
                  'First time on this computer? Bring the phone\'s backup '
                  'down once, then sync keeps the two in step.',
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DriveBackupScreen(
                      db: widget.db,
                      prefs: widget.prefs,
                      intake: true,
                    ),
                  ),
                ),
                child: const Text('BRING THE PHONE\'S COPY'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
