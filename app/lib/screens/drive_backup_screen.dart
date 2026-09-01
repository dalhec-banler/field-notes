import 'package:flutter/material.dart';

import 'package:path_provider/path_provider.dart';

import '../backup/backup_service.dart';
import '../backup/drive_auth.dart';
import '../backup/drive_target.dart';
import '../backup/restore.dart';
import '../db/database.dart';
import '../desktop/relaunch.dart';
import '../services/app_prefs.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Back up to the user's own Google Drive (D-020).
///
/// The convenience option, and the screen says so plainly rather than
/// selling it. A copy that survives a lost phone without you remembering to
/// plug anything in is worth having; the cost is that a company knows a file
/// arrived. It cannot know what is in it.
class DriveBackupScreen extends StatefulWidget {
  DriveBackupScreen({
    super.key,
    required this.db,
    required this.prefs,
    this.intake = false,
  });

  /// Intake (D-024): a computer with no record yet. There is nothing to back
  /// up, so the screen is Connect → Restore → reopen, and says so.
  final bool intake;

  final FieldNotesDb db;
  final AppPrefs prefs;

  @override
  State<DriveBackupScreen> createState() => _DriveBackupScreenState();
}

class _DriveBackupScreenState extends State<DriveBackupScreen> {
  late final _service = BackupService(widget.db);
  bool _busy = false;
  bool _supported = true;
  String? _email;
  String? _status;

  /// A restore is staged: on a computer, offer the reopen right here.
  bool _staged = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Opening this screen must not talk to Google. The remembered address is
  /// enough to say which account is connected, and asking Google instead put
  /// its account picker on screen before the user had touched anything.
  Future<void> _refresh() async {
    final supported = await DriveAuth.instance.isSupported;
    // The desk keeps its grant in the keychain; label from that, locally.
    await DriveAuth.instance.primeDeskEmail();
    if (!mounted) return;
    setState(() {
      _supported = supported;
      _email = DriveAuth.instance.lastKnownEmail ?? widget.prefs.driveEmail;
    });
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _status = 'Opening Google sign-in…';
    });
    try {
      final token = await DriveAuth.instance.accessToken(interactive: true);
      if (token == null) {
        if (mounted) setState(() => _status = 'Not connected.');
        return;
      }
      final email = DriveAuth.instance.lastKnownEmail;
      widget.prefs.driveEmail = email;
      if (mounted) {
        setState(() {
          _email = email;
          _status = 'Connected. Backups can go to this account.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    await DriveAuth.instance.disconnect();
    widget.prefs.driveEmail = null;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _email = null;
      _status =
          'Disconnected. Copies already in Drive are still there — '
          'remove them from Drive’s storage settings if you want them gone.';
    });
  }

  Future<void> _backup() async {
    setState(() {
      _busy = true;
      _status = 'Connecting to Drive…';
    });
    DriveTarget? target;
    try {
      final token = await DriveAuth.instance.accessToken(interactive: true);
      if (token == null) {
        if (mounted) setState(() => _status = 'Not connected.');
        return;
      }
      // Someone can go straight to Back up now without tapping Connect;
      // remember the account so the screen can name it next time.
      widget.prefs.driveEmail = DriveAuth.instance.lastKnownEmail;
      if (mounted) setState(() => _email = widget.prefs.driveEmail);
      target = DriveTarget(accessToken: token);
      final engine = await _service.engineForTarget(
        target,
        askPassphrase: () => _askPassphrase(context),
        onStatus: (s) => mounted ? setState(() => _status = s) : null,
      );
      if (engine == null) {
        if (mounted) setState(() => _status = null);
        return;
      }
      if (mounted) setState(() => _status = 'Uploading…');
      final summary = await _service.backupNow(engine);
      if (mounted) setState(() => _status = summary);
    } catch (e) {
      if (mounted) setState(() => _status = 'Backup failed: $e');
    } finally {
      target?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Read every object back from Drive and check it against the manifest —
  /// the proof that the copy up there is real, run against Drive itself.
  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _status = 'Reading the backup back from Drive…';
    });
    DriveTarget? target;
    try {
      final token = await DriveAuth.instance.accessToken(interactive: true);
      if (token == null) {
        if (mounted) setState(() => _status = 'Not connected.');
        return;
      }
      target = DriveTarget(accessToken: token);
      final engine = await _service.engineForTarget(
        target,
        askPassphrase: () => _askPassphrase(context),
        onStatus: (s) => mounted ? setState(() => _status = s) : null,
      );
      if (engine == null) {
        if (mounted) setState(() => _status = null);
        return;
      }
      final problem = await _service.verifyNow(engine);
      if (mounted) {
        setState(
          () => _status = problem == null
              ? 'Verified: every object in Drive reads back intact.'
              : 'Verify found a problem: $problem',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Verify failed: $e');
    } finally {
      target?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Restore from the Drive copy. Stages only — the swap happens on the
  /// next launch, the old database is kept aside, and a corrupt backup is
  /// refused before anything live is touched (spec §11.9, audit P3).
  Future<void> _restore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('RESTORE FROM DRIVE?'),
        content: Text(
          widget.intake
              ? 'The copy in Drive becomes this computer\'s record the next time '
                    'Field Notes opens. Nothing changes until the copy has been '
                    'read back whole and checked.'
              : 'The backup in Drive will replace what is on this device the '
                    'next time the app starts. The current database is kept '
                    'aside, and nothing changes until the backup has been read '
                    'back whole and checked.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('RESTORE'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _status = 'Downloading the backup from Drive…';
    });
    DriveTarget? target;
    try {
      final token = await DriveAuth.instance.accessToken(interactive: true);
      if (token == null) {
        if (mounted) setState(() => _status = 'Not connected.');
        return;
      }
      target = DriveTarget(accessToken: token);
      if (!await target.exists('fieldnotes/manifest.json')) {
        if (mounted) setState(() => _status = 'No backup found in Drive.');
        return;
      }
      final docs = await getApplicationDocumentsDirectory();
      final pipeline = RestorePipeline(docs);
      try {
        final summary = await pipeline.stageFromTarget(target);
        if (mounted) {
          setState(() {
            _status = summary;
            _staged = true;
          });
        }
      } on StateError catch (e) {
        if (!e.toString().contains('encrypted')) rethrow;
        final secret = await _askPassphrase(context);
        if (secret == null || secret.isEmpty) {
          if (mounted) setState(() => _status = null);
          return;
        }
        if (mounted) setState(() => _status = 'Unlocking and staging…');
        final summary = await pipeline.stageFromTarget(target, secret: secret);
        if (mounted) {
          setState(() {
            _status = summary;
            _staged = true;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Restore failed: $e');
    } finally {
      target?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPassphrase(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('BACKUP PASSPHRASE'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: InputDecoration(labelText: 'Passphrase'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text('CONTINUE'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = _email != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.intake
              ? 'Bring the record from Drive'
              : 'Back up to Google Drive',
        ),
      ),
      body: ListView(
        padding: EdgeInsets.all(Metrics.gutter),
        children: [
          if (widget.intake) ...[
            Text(
              'If the phone backs up to Google Drive, this computer can fetch '
              'that copy. Connect with the same Google account, restore, and '
              'reopen Field Notes. The copy is encrypted; you will be asked '
              'for the passphrase or recovery phrase to open it.',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 15.5,
                height: 1.45,
              ),
            ),
          ] else ...[
            Text(
              'A copy goes to a hidden folder in your own Drive — one this app '
              'creates for itself, which nothing else can open and which does '
              'not appear alongside your files. The phone encrypts everything '
              'before it leaves, so Google stores the copy and cannot read it.',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 15.5,
                height: 1.45,
              ),
            ),
            SizedBox(height: 14),
            Text(
              'This is the convenient option, not the private one. Backing up '
              'to your own computer over your own network keeps the copy in '
              'the house. Both work; you can use both.',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 15.5,
                height: 1.45,
              ),
            ),
          ],
          SizedBox(height: 20),
          if (!_supported)
            Text(
              'Google sign-in isn’t available in this build. The LAN backup '
              'and the local copy both still work.',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 15.5,
                height: 1.45,
              ),
            )
          else ...[
            MonoLabel('Account', size: 9, spacing: 1.8),
            SizedBox(height: 8),
            Text(
              connected ? _email! : 'Not connected',
              style: TextStyle(
                fontFamily: Type.serif,
                fontSize: 16,
                height: 1.35,
              ),
            ),
            SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : (connected ? _disconnect : _connect),
                      child: Text(connected ? 'DISCONNECT' : 'CONNECT'),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: FilledButton(
                      // Intake: the one thing a fresh computer does here.
                      onPressed: _busy
                          ? null
                          : widget.intake
                          ? (connected ? _restore : null)
                          : _backup,
                      child: Text(
                        _busy
                            ? 'WORKING…'
                            : widget.intake
                            ? 'RESTORE FROM DRIVE'
                            : 'BACK UP NOW',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (!widget.intake) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: OutlinedButton(
                        onPressed: _busy ? null : _verify,
                        child: const Text('VERIFY'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: OutlinedButton(
                        onPressed: _busy ? null : _restore,
                        child: const Text('RESTORE FROM DRIVE'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (_staged && canRelaunch) ...[
              const SizedBox(height: 14),
              SizedBox(
                height: 56,
                child: FilledButton(
                  onPressed: relaunchApp,
                  child: const Text('QUIT & REOPEN'),
                ),
              ),
            ],
          ],
          if (_status != null)
            Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text(
                _status!,
                style: TextStyle(
                  fontFamily: Type.serif,
                  fontSize: 15.5,
                  height: 1.4,
                ),
              ),
            ),
          SizedBox(height: 20),
          MonoLabel(
            'You can revoke this at myaccount.google.com/permissions at any '
            'time. The app keeps working; it just stops uploading.',
            size: 9,
            opacity: 0.7,
          ),
        ],
      ),
    );
  }
}
