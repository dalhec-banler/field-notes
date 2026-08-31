import 'package:flutter/material.dart';

import '../backup/backup_service.dart';
import '../backup/drive_auth.dart';
import '../backup/drive_target.dart';
import '../db/database.dart';
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
  DriveBackupScreen({super.key, required this.db, required this.prefs});

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
      _status = 'Disconnected. Copies already in Drive are still there — '
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
              onPressed: () => Navigator.pop(ctx), child: Text('CANCEL')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text('CONTINUE')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = _email != null;
    return Scaffold(
      appBar: AppBar(title: Text('Back up to Google Drive')),
      body: ListView(
        padding: EdgeInsets.all(Metrics.gutter),
        children: [
          Text(
            'A copy goes to a hidden folder in your own Drive — one this app '
            'creates for itself, which nothing else can open and which does '
            'not appear alongside your files. The phone encrypts everything '
            'before it leaves, so Google stores the copy and cannot read it.',
            style:
                TextStyle(fontFamily: Type.serif, fontSize: 15.5, height: 1.45),
          ),
          SizedBox(height: 14),
          Text(
            'This is the convenient option, not the private one. Backing up '
            'to your own computer over your own network keeps the copy in '
            'the house. Both work; you can use both.',
            style:
                TextStyle(fontFamily: Type.serif, fontSize: 15.5, height: 1.45),
          ),
          SizedBox(height: 20),
          if (!_supported)
            Text(
              'Google sign-in isn’t available in this build. The LAN backup '
              'and the local copy both still work.',
              style: TextStyle(
                  fontFamily: Type.serif, fontSize: 15.5, height: 1.45),
            )
          else ...[
            MonoLabel('Account', size: 9, spacing: 1.8),
            SizedBox(height: 8),
            Text(
              connected ? _email! : 'Not connected',
              style: TextStyle(
                  fontFamily: Type.serif, fontSize: 16, height: 1.35),
            ),
            SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: OutlinedButton(
                      onPressed: _busy ? null : (connected ? _disconnect : _connect),
                      child: Text(connected ? 'DISCONNECT' : 'CONNECT'),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: FilledButton(
                      onPressed: _busy ? null : _backup,
                      child: Text(_busy ? 'WORKING…' : 'BACK UP NOW'),
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_status != null)
            Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text(_status!,
                  style: TextStyle(
                      fontFamily: Type.serif, fontSize: 15.5, height: 1.4)),
            ),
          SizedBox(height: 20),
          MonoLabel(
              'You can revoke this at myaccount.google.com/permissions at any '
              'time. The app keeps working; it just stops uploading.',
              size: 9,
              opacity: 0.7),
        ],
      ),
    );
  }
}
