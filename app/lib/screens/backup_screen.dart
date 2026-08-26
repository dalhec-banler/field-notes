import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../backup/backup_service.dart';
import '../db/database.dart';
import '../services/app_prefs.dart';

/// Backup (spec §11 + D-010).
///
/// v1 target is a local backup folder the user copies off-device (USB, or a
/// folder synced by the Drive/Syncthing app). The engine is target-pluggable;
/// native Google Drive upload lands once OAuth credentials exist.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.db, this.prefs});

  final FieldNotesDb db;

  /// Optional: the desktop shell opens this without a prefs handle.
  final AppPrefs? prefs;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  late final _service = BackupService(widget.db);
  AppPrefs? _prefs;
  bool _encrypted = false; // D-010: convenience is a fine default
  bool _busy = false;
  bool _keyCached = false;
  String? _status;
  String? _lastBackup;
  String? _lastVerify;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await _service.loadConfig();
    final cached = await _service.hasCachedKey;
    _prefs ??= widget.prefs ?? await AppPrefs.load();
    if (mounted) {
      setState(() {
        _encrypted = config['scheme'] == 'keyring-v1';
        _lastBackup = config['last_backup'] as String?;
        _lastVerify = config['last_verify'] as String?;
        _keyCached = cached;
      });
    }
  }

  Future<void> _showRecoveryKit(String phrase) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('YOUR RECOVERY KIT'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'These 12 words can unlock your backup if you forget the '
                'passphrase. Write them down or save them in a password '
                'manager. They are shown exactly once.'),
            const SizedBox(height: 12),
            SelectableText(
              phrase,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("I'VE SAVED THESE WORDS"),
          ),
        ],
      ),
    );
  }

  Future<String?> _askPassphrase({bool confirm = false}) async {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          final mismatch = confirm &&
              confirmController.text.isNotEmpty &&
              confirmController.text != controller.text;
          return AlertDialog(
            title: const Text('BACKUP PASSPHRASE'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: true,
                  onChanged: (_) => setDialog(() {}),
                  decoration: const InputDecoration(labelText: 'Passphrase'),
                ),
                if (confirm) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: confirmController,
                    obscureText: true,
                    onChanged: (_) => setDialog(() {}),
                    decoration: InputDecoration(
                      labelText: 'Type it again',
                      errorText: mismatch ? 'Doesn\'t match' : null,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                const Text(
                  'If you lose this passphrase, the backup cannot be opened by '
                  'anyone — including you. The recovery kit is the only other '
                  'way in.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('CANCEL')),
              FilledButton(
                  onPressed: controller.text.isEmpty ||
                          (confirm && confirmController.text != controller.text)
                      ? null
                      : () => Navigator.pop(context, controller.text),
                  child: const Text('CONTINUE')),
            ],
          );
        },
      ),
    );
    return result;
  }

  Future<void> _run(String label, Future<String?> Function() body) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = label;
    });
    try {
      final result = await body();
      if (mounted) setState(() => _status = result);
    } catch (e) {
      if (mounted) setState(() => _status = '$label failed: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _loadConfig();
      }
    }
  }

  Future<void> _backupNow() => _run('Backing up…', () async {
        final config = await _service.loadConfig();
        final firstSetup = _encrypted && config['wrap_pass'] == null;
        final engine = await _service.engine(
          encrypted: _encrypted,
          setupIfNeeded: true,
          askPassphrase: () => _askPassphrase(confirm: firstSetup),
          onRecoveryPhrase: _showRecoveryKit,
          onStatus: (s) => setState(() => _status = s),
        );
        if (engine == null) return _status == 'Wrong passphrase.' ? _status : null;
        return _service.backupNow(engine);
      });

  Future<void> _verifyNow() => _run('Verifying…', () async {
        final engine = await _service.engine(
          encrypted: _encrypted,
          askPassphrase: _askPassphrase,
          onStatus: (s) => setState(() => _status = s),
        );
        if (engine == null) return 'Run a backup first.';
        final problem = await _service.verifyNow(engine);
        return problem == null ? 'Backup verified ✓' : 'Problem: $problem';
      });

  /// Zips the whole backup store and hands it to the share sheet — one tap to
  /// get the backup off the phone (Drive, email, a computer).
  Future<void> _shareZip() => _run('Zipping backup…', () async {
        final dir = await _service.backupDir();
        if (!Directory('${dir.path}/fieldnotes').existsSync()) {
          return 'Run a backup first.';
        }
        final docs = await getApplicationDocumentsDirectory();
        final date = nowUtcIso().substring(0, 10);
        final zipPath = p.join(docs.path, 'fieldnotes-backup-$date.zip');
        final encoder = ZipFileEncoder();
        encoder.create(zipPath);
        await encoder.addDirectory(Directory('${dir.path}/fieldnotes'));
        await encoder.close();
        await SharePlus.instance.share(
            ShareParams(files: [XFile(zipPath)], text: 'Field Notes backup'));
        return 'Backup shared.';
      });

  String _ago(String? iso) {
    if (iso == null) return 'never';
    final then = DateTime.tryParse(iso);
    if (then == null) return iso;
    final d = DateTime.now().toUtc().difference(then);
    if (d.inDays > 0) return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
    if (d.inHours > 0) return '${d.inHours} h ago';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Last backup: ${_ago(_lastBackup)}',
                      style: Theme.of(context).textTheme.titleMedium),
                  Text('Last verified: ${_ago(_lastVerify)}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Encrypt with a passphrase'),
            subtitle: Text(_encrypted
                ? 'Backups are unreadable without your passphrase. Losing it '
                    'means losing the backup.'
                : 'Convenience mode: backups are stored unencrypted. Anyone '
                    'with the files can read your records and locations.'),
            value: _encrypted,
            onChanged: _busy ? null : (v) => setState(() => _encrypted = v),
          ),
          SwitchListTile(
            title: const Text('Back up automatically'),
            subtitle: Text(_encrypted && !_keyCached
                ? 'Once a day. Needs the passphrase once on this phone — '
                    'run "Back up now" to unlock it.'
                : 'Once a day while you use the app, plus a weekly check '
                    'that the backup still opens.'),
            value: _prefs?.autoBackup ?? true,
            onChanged: _busy || _prefs == null
                ? null
                : (v) => setState(() => _prefs!.autoBackup = v),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              icon: const Icon(Icons.backup_outlined),
              label: Text(_busy ? 'Working…' : 'BACK UP NOW'),
              onPressed: _busy ? null : _backupNow,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 56,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.verified_outlined),
              label: const Text('VERIFY BACKUP'),
              onPressed: _busy ? null : _verifyNow,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 56,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.ios_share),
              label: const Text('SHARE BACKUP (ZIP)'),
              onPressed: _busy ? null : _shareZip,
            ),
          ),
          if (_encrypted && _keyCached) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      await _service.forgetKey();
                      _loadConfig();
                      if (mounted) {
                        setState(() => _status =
                            'Passphrase forgotten on this phone. The next '
                            'backup will ask for it.');
                      }
                    },
              child: const Text('FORGET PASSPHRASE ON THIS PHONE'),
            ),
          ],
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_status!,
                  style: Theme.of(context).textTheme.bodyLarge),
            ),
          const SizedBox(height: 24),
          Text(
            'Backups are written to the app\'s backups folder on this phone. '
            'Share the zip to a computer, drive, or cloud folder to protect '
            'against losing the phone. Direct Google Drive upload is coming.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
