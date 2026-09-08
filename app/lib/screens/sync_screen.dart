import 'package:flutter/material.dart';

import '../backup/drive_auth.dart';
import '../db/database.dart';
import '../main.dart' show opLog;
import '../services/app_prefs.dart';
import '../services/desk.dart';
import '../sync/sync_service.dart';
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
  String? _lastAt;
  String? _lastNote;
  int _pending = 0;
  int _mediaMissing = 0;
  bool _busy = false;
  String? _status;
  bool _hasProperty = true;

  @override
  void initState() {
    super.initState();
    final log = opLog;
    if (log != null) _service = SyncService(widget.db, widget.prefs, log);
    _load();
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
    final at = await s.lastSyncAt;
    final note = await s.lastNote;
    final pending = await s.pending;
    final missing = await s.mediaMissing;
    if (!mounted) return;
    setState(() {
      _lastAt = at;
      _lastNote = note;
      _pending = pending;
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

  String _ago(String? iso) {
    if (iso == null) return 'never';
    final then = DateTime.tryParse(iso);
    if (then == null) return iso;
    final d = DateTime.now().toUtc().difference(then);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.prefs.driveEmail != null;
    final unavailable = _service == null;
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
                FactRow('Account', widget.prefs.driveEmail ?? 'Not connected'),
                FactRow('Last synced', _ago(_lastAt)),
                FactRow(
                  'Waiting to send',
                  _pending == 0
                      ? 'nothing'
                      : '$_pending change${_pending == 1 ? '' : 's'}',
                ),
                if (_mediaMissing > 0)
                  FactRow('Photos to fetch', '$_mediaMissing'),
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
