import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import '../services/app_prefs.dart';
import 'backup_crypto.dart';
import 'backup_engine.dart';
import 'key_cache.dart';
import 'keyring.dart';
import 'target.dart';

/// One owner for backup config, key handling and the schedule, shared by
/// the Backup screen and the automatic runner (spec §11.7–11.8).
///
/// Config (`backup_config.json`, plaintext, safe): scheme, keyring salts and
/// wrapped keys, last_backup, last_verify, last_auto_attempt.
/// Secrets: the raw data key lives only in the platform key cache.
class BackupService {
  BackupService(this.db, {BackupKeyCache? keyCache})
      : _keyCache = keyCache ?? BackupKeyCache();

  final FieldNotesDb db;
  final BackupKeyCache _keyCache;

  static const configName = 'backup_config.json';
  static const autoInterval = Duration(hours: 24);
  static const verifyInterval = Duration(days: 7);

  Future<Directory> backupDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'backups'))..createSync(recursive: true);
  }

  Future<File> _configFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, configName));
  }

  Future<Map<String, dynamic>> loadConfig() async {
    final f = await _configFile();
    if (!f.existsSync()) return {};
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveConfig(Map<String, Object?> updates) async {
    final f = await _configFile();
    final config = await loadConfig();
    config.addAll(updates);
    f.writeAsStringSync(jsonEncode(config));
  }

  /// Is a backup configured at all (plain or encrypted)?
  Future<bool> get isConfigured async =>
      (await loadConfig())['scheme'] != null;

  /// Can the encrypted engine be built without asking for the passphrase?
  Future<bool> get hasCachedKey async => (await _keyCache.read()) != null;

  /// Build an engine for the current config.
  ///
  /// Encrypted mode tries the key cache first; if empty, [askPassphrase] is
  /// consulted (null → give up). [setupIfNeeded] mints a new keyring when
  /// none exists; the recovery phrase is handed to [onRecoveryPhrase] once.
  Future<BackupEngine?> engine({
    required bool encrypted,
    Future<String?> Function()? askPassphrase,
    bool setupIfNeeded = false,
    Future<void> Function(String phrase)? onRecoveryPhrase,
    void Function(String status)? onStatus,
  }) async {
    final target = DirectoryTarget(await backupDir());
    final config = await loadConfig();

    if (!encrypted) {
      // Switching to plain keeps the keyring fields in config so a later
      // switch back re-uses the same key instead of orphaning old blobs.
      await saveConfig({'scheme': 'plain'});
      return BackupEngine(db, target, const PlainCipher());
    }

    final hasKeyring = config['wrap_pass'] != null;
    if (hasKeyring) {
      final cached = await _keyCache.read();
      if (cached != null) {
        final keyring = BackupKeyring.fromCachedKey(cached, config);
        await saveConfig({'scheme': 'keyring-v1'});
        return BackupEngine(db, target, keyring.cipher,
            envelopeExtra: keyring.envelopeFields..['scheme'] = 'keyring-v1');
      }
      final passphrase = await askPassphrase?.call();
      if (passphrase == null || passphrase.isEmpty) return null;
      onStatus?.call('Unlocking… (a second or two)');
      try {
        final keyring =
            await BackupKeyring.unlockWithPassphrase(config, passphrase);
        await _keyCache.write(await keyring.dataKeyBytes());
        await saveConfig({'scheme': 'keyring-v1'});
        return BackupEngine(db, target, keyring.cipher,
            envelopeExtra: keyring.envelopeFields..['scheme'] = 'keyring-v1');
      } catch (_) {
        onStatus?.call('Wrong passphrase.');
        return null;
      }
    }

    if (!setupIfNeeded) return null;
    final passphrase = await askPassphrase?.call();
    if (passphrase == null || passphrase.isEmpty) return null;
    onStatus?.call('Creating keys… (a few seconds)');
    final keyring = await BackupKeyring.create(passphrase);
    await saveConfig({...keyring.envelopeFields, 'scheme': 'keyring-v1'});
    await _keyCache.write(await keyring.dataKeyBytes());
    if (onRecoveryPhrase != null) {
      await onRecoveryPhrase(keyring.recoveryPhrase!);
    }
    return BackupEngine(db, target, keyring.cipher,
        envelopeExtra: keyring.envelopeFields);
  }

  /// Forget the cached key: next encrypted backup asks for the passphrase.
  Future<void> forgetKey() => _keyCache.clear();

  Future<String> backupNow(BackupEngine engine) async {
    final summary = await engine.backup();
    await saveConfig({'last_backup': nowUtcIso()});
    return summary;
  }

  /// Returns null on success, else the problem.
  Future<String?> verifyNow(BackupEngine engine) async {
    final problem = await engine.verify();
    if (problem == null) await saveConfig({'last_verify': nowUtcIso()});
    return problem;
  }

  /// The automatic runner. Call on launch and on resume; it decides.
  /// Local-folder target needs no network, so the only gates are the
  /// user's switch, the daily interval, and (encrypted) a cached key.
  /// Returns a one-line note when it did something, else null.
  Future<String?> maybeRunAutomatic(AppPrefs prefs) async {
    if (!prefs.autoBackup) return null;
    final config = await loadConfig();
    final scheme = config['scheme'] as String?;
    if (scheme == null) return null; // never set up — nothing to automate

    bool due(String key, Duration every) {
      final iso = config[key] as String?;
      final then = iso == null ? null : DateTime.tryParse(iso);
      return then == null || DateTime.now().toUtc().difference(then) >= every;
    }

    // Don't hammer a failing setup: one attempt per interval, success or not.
    if (!due('last_auto_attempt', const Duration(hours: 6))) return null;
    await saveConfig({'last_auto_attempt': nowUtcIso()});

    final encrypted = scheme == 'keyring-v1';
    if (encrypted && !await hasCachedKey) {
      return 'Automatic backup needs the passphrase once — open Backup.';
    }

    final notes = <String>[];
    if (due('last_backup', autoInterval)) {
      final engine = await this.engine(encrypted: encrypted);
      if (engine == null) return null;
      try {
        notes.add(await backupNow(engine));
      } catch (e) {
        return 'Automatic backup failed: $e';
      }
    }
    if (due('last_verify', verifyInterval)) {
      final engine = await this.engine(encrypted: encrypted);
      if (engine != null) {
        final problem = await verifyNow(engine);
        notes.add(problem == null ? 'verified' : 'verify problem: $problem');
      }
    }
    return notes.isEmpty ? null : notes.join(' · ');
  }
}
