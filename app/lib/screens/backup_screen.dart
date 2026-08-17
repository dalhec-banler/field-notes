import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../backup/backup_crypto.dart';
import '../backup/backup_engine.dart';
import '../backup/target.dart';
import '../db/database.dart';

/// Backup (spec §11 + D-010).
///
/// v1 target is a local backup folder the user copies off-device (USB, or a
/// folder synced by the Drive/Syncthing app). The engine is target-pluggable;
/// native Google Drive upload lands once OAuth credentials exist.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.db});

  final FieldNotesDb db;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool _encrypted = false; // D-010: convenience is a fine default
  bool _busy = false;
  String? _status;
  String? _lastBackup;
  String? _lastVerify;

  static const _configName = 'backup_config.json';

  Future<Directory> _backupDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'backups'))..createSync(recursive: true);
  }

  Future<File> _configFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, _configName));
  }

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final f = await _configFile();
    if (!f.existsSync()) return;
    final config = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    if (mounted) {
      setState(() {
        _encrypted = config['scheme'] == 'argon2id-xchacha20';
        _lastBackup = config['last_backup'] as String?;
        _lastVerify = config['last_verify'] as String?;
      });
    }
  }

  Future<void> _saveConfig(Map<String, Object?> updates) async {
    final f = await _configFile();
    final config = f.existsSync()
        ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};
    config.addAll(updates);
    f.writeAsStringSync(jsonEncode(config));
  }

  Future<BackupEngine?> _engine({required bool forSetupIfNeeded}) async {
    final dir = await _backupDir();
    final target = DirectoryTarget(dir);
    if (!_encrypted) {
      await _saveConfig({'scheme': 'plain'});
      return BackupEngine(widget.db, target, const PlainCipher());
    }

    // Encrypted: salt persists in config; passphrase asked per operation.
    final f = await _configFile();
    final config = f.existsSync()
        ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};
    var saltB64 = config['salt'] as String?;
    if (saltB64 == null) {
      if (!forSetupIfNeeded) return null;
      saltB64 = base64Encode(BackupEngine.newSalt());
      await _saveConfig({'scheme': 'argon2id-xchacha20', 'salt': saltB64});
    }
    final passphrase = await _askPassphrase();
    if (passphrase == null || passphrase.isEmpty) return null;
    setState(() => _status = 'Deriving key… (~1 s)');
    final cipher =
        await PassphraseCipher.fromPassphrase(passphrase, base64Decode(saltB64));
    return BackupEngine(widget.db, target, cipher, saltB64: saltB64);
  }

  Future<String?> _askPassphrase() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Backup passphrase'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Passphrase'),
            ),
            const SizedBox(height: 8),
            const Text(
              'If you lose this passphrase, the backup cannot be opened by '
              'anyone — including you.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Continue')),
        ],
      ),
    );
  }

  Future<void> _backupNow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Backing up…';
    });
    try {
      final engine = await _engine(forSetupIfNeeded: true);
      if (engine == null) {
        setState(() => _status = null);
        return;
      }
      final summary = await engine.backup();
      final now = nowUtcIso();
      await _saveConfig({'last_backup': now});
      setState(() {
        _status = summary;
        _lastBackup = now;
      });
    } catch (e) {
      setState(() => _status = 'Backup failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _verifyNow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Verifying…';
    });
    try {
      final engine = await _engine(forSetupIfNeeded: false);
      if (engine == null) {
        setState(() => _status = 'Run a backup first.');
        return;
      }
      final problem = await engine.verify();
      final now = nowUtcIso();
      if (problem == null) await _saveConfig({'last_verify': now});
      setState(() {
        _status = problem == null ? 'Backup verified ✓' : 'Problem: $problem';
        if (problem == null) _lastVerify = now;
      });
    } catch (e) {
      setState(() => _status = 'Verify failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

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
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              icon: const Icon(Icons.backup_outlined),
              label: Text(_busy ? 'Working…' : 'Back up now'),
              onPressed: _busy ? null : _backupNow,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 56,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.verified_outlined),
              label: const Text('Verify backup'),
              onPressed: _busy ? null : _verifyNow,
            ),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_status!,
                  style: Theme.of(context).textTheme.bodyLarge),
            ),
          const SizedBox(height: 24),
          Text(
            'Backups are written to the app\'s backups folder on this phone. '
            'Copy that folder to a computer, drive, or synced folder to '
            'protect against losing the phone. Direct Google Drive upload is '
            'coming.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
