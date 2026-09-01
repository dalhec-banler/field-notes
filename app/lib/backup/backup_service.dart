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
/// wrapped keys, last_backup, last_verify, last_auto_attempt, last_auto_note.
/// Secrets: the raw data key lives only in the platform key cache.
///
/// Rules that keep an encrypted store safe:
///  * [engine] is pure — it never writes config. The scheme is recorded only
///    after a backup actually succeeds ([backupNow]).
///  * One backup at a time, process-wide ([_lock]), so the automatic runner
///    and a "Back up now" can't both write the same generation.
///  * The automatic runner refuses to write a store whose manifest scheme
///    disagrees with the config — it will never convert an encrypted store
///    to plain (or vice versa) on its own.
///  * Config writes are atomic (tmp + rename); a corrupt file is reported,
///    not treated as "never set up".
class BackupService {
  BackupService(this.db, {BackupKeyCache? keyCache})
    : _keyCache = keyCache ?? BackupKeyCache();

  final FieldNotesDb db;
  final BackupKeyCache _keyCache;

  static const configName = 'backup_config.json';
  static const autoInterval = Duration(hours: 24);
  static const verifyInterval = Duration(days: 7);

  /// Process-wide serialisation of backup/verify work.
  static Future<void> _lock = Future.value();
  static bool _busy = false;
  static bool get busy => _busy;

  static Future<T> _serialized<T>(Future<T> Function() body) {
    final run = _lock.then((_) async {
      _busy = true;
      try {
        return await body();
      } finally {
        _busy = false;
      }
    });
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Directory> backupDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(p.join(docs.path, 'backups'))..createSync(recursive: true);
  }

  Future<File> _configFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, configName));
  }

  /// Null when the file exists but can't be parsed — callers must not
  /// mistake that for "not configured".
  Future<Map<String, dynamic>?> loadConfigOrNull() async {
    final f = await _configFile();
    if (!f.existsSync()) return {};
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> loadConfig() async =>
      (await loadConfigOrNull()) ?? {};

  Future<void> saveConfig(Map<String, Object?> updates) async {
    final f = await _configFile();
    final config = await loadConfigOrNull();
    if (config == null) {
      throw StateError('backup_config.json is unreadable — not overwriting it');
    }
    config.addAll(updates);
    // Atomic: a crash mid-write must not leave half a file.
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(config), flush: true);
    tmp.renameSync(f.path);
  }

  /// Is a backup configured at all (plain or encrypted)?
  Future<bool> get isConfigured async => (await loadConfig())['scheme'] != null;

  /// Can the encrypted engine be built without asking for the passphrase?
  Future<bool> get hasCachedKey async => (await _keyCache.read()) != null;

  /// Scheme of the manifest actually on disk, or null if there is none.
  Future<String?> storeScheme() async {
    final f = File(
      p.join((await backupDir()).path, BackupEngine.root, 'manifest.json'),
    );
    if (!f.existsSync()) return null;
    try {
      return (jsonDecode(f.readAsStringSync()) as Map)['scheme'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Build an engine for the requested mode. Pure: writes no config.
  ///
  /// Encrypted mode tries the key cache first; if empty, [askPassphrase] is
  /// consulted (null → give up). [setupIfNeeded] mints a new keyring when
  /// none exists; the recovery phrase is handed to [onRecoveryPhrase] once.
  /// Same key handling as [engine], but pointed at an arbitrary target —
  /// a computer on the network rather than the folder on this phone. The
  /// keyring is shared, so a LAN backup is readable by the same passphrase
  /// and recovery kit as every other copy.
  Future<BackupEngine?> engineForTarget(
    BackupTarget target, {
    Future<String?> Function()? askPassphrase,
    void Function(String status)? onStatus,
  }) async {
    final config = await loadConfigOrNull();
    if (config == null) {
      onStatus?.call('Backup settings file is damaged — see Settings.');
      return null;
    }
    final encrypted =
        config['scheme'] == 'keyring-v1' || config['wrap_pass'] != null;
    if (!encrypted) {
      return BackupEngine(db, target, const PlainCipher());
    }
    final fields = Map<String, Object?>.from(config)..['scheme'] = 'keyring-v1';
    final cached = await _keyCache.read();
    if (cached != null) {
      final keyring = BackupKeyring.fromCachedKey(cached, config);
      return BackupEngine(db, target, keyring.cipher, envelopeExtra: fields);
    }
    final passphrase = await askPassphrase?.call();
    if (passphrase == null || passphrase.isEmpty) return null;
    onStatus?.call('Unlocking…');
    try {
      final keyring = await BackupKeyring.unlockWithPassphrase(
        config,
        passphrase,
      );
      await _keyCache.write(await keyring.dataKeyBytes());
      return BackupEngine(db, target, keyring.cipher, envelopeExtra: fields);
    } catch (_) {
      onStatus?.call('Wrong passphrase.');
      return null;
    }
  }

  Future<BackupEngine?> engine({
    required bool encrypted,
    Future<String?> Function()? askPassphrase,
    bool setupIfNeeded = false,
    Future<void> Function(String phrase)? onRecoveryPhrase,
    void Function(String status)? onStatus,
  }) async {
    final target = DirectoryTarget(await backupDir());
    final config = await loadConfigOrNull();
    if (config == null) {
      onStatus?.call('Backup settings file is damaged — see Settings.');
      return null;
    }

    if (!encrypted) {
      return BackupEngine(db, target, const PlainCipher());
    }

    final hasKeyring = config['wrap_pass'] != null;
    if (hasKeyring) {
      final fields = Map<String, Object?>.from(config)
        ..['scheme'] = 'keyring-v1';
      final cached = await _keyCache.read();
      if (cached != null) {
        final keyring = BackupKeyring.fromCachedKey(cached, config);
        return BackupEngine(db, target, keyring.cipher, envelopeExtra: fields);
      }
      final passphrase = await askPassphrase?.call();
      if (passphrase == null || passphrase.isEmpty) return null;
      onStatus?.call('Unlocking… (a second or two)');
      try {
        final keyring = await BackupKeyring.unlockWithPassphrase(
          config,
          passphrase,
        );
        await _keyCache.write(await keyring.dataKeyBytes());
        return BackupEngine(db, target, keyring.cipher, envelopeExtra: fields);
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
    // The wrapped keys must be on disk before any blob is written with the
    // new data key, or a crash mid-backup would orphan them.
    await saveConfig({...keyring.envelopeFields});
    await _keyCache.write(await keyring.dataKeyBytes());
    if (onRecoveryPhrase != null) {
      await onRecoveryPhrase(keyring.recoveryPhrase!);
    }
    return BackupEngine(
      db,
      target,
      keyring.cipher,
      envelopeExtra: keyring.envelopeFields,
    );
  }

  /// Forget the cached key: next encrypted backup asks for the passphrase.
  Future<void> forgetKey() => _keyCache.clear();

  /// Runs a backup (serialized). Records the scheme only on success.
  Future<String> backupNow(BackupEngine engine) => _serialized(() async {
    final summary = await engine.backup();
    await saveConfig({
      'last_backup': nowUtcIso(),
      'scheme': engine.cipher.scheme,
    });
    return summary;
  });

  /// Returns null on success, else the problem. Serialized.
  Future<String?> verifyNow(BackupEngine engine) => _serialized(() async {
    final problem = await engine.verify();
    if (problem == null) await saveConfig({'last_verify': nowUtcIso()});
    return problem;
  });

  /// The automatic runner. Call on launch and on resume; it decides.
  /// Local-folder target needs no network, so the only gates are the
  /// user's switch, the daily interval, and (encrypted) a cached key.
  /// Returns a one-line note when it did (or couldn't do) something; the
  /// note is also persisted as `last_auto_note` for the Backup screen.
  Future<String?> maybeRunAutomatic(AppPrefs prefs) async {
    if (!prefs.autoBackup) return null;
    if (_busy) return null; // a manual run is in flight
    final config = await loadConfigOrNull();
    if (config == null) {
      return _note('Backup settings file is damaged — open Backup to fix.');
    }
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

    // Never convert a store. If what's on disk disagrees with the config,
    // stop and say so.
    final onDisk = await storeScheme();
    if (onDisk != null && onDisk != scheme) {
      return _note(
        'Backup paused: the store is $onDisk but settings say '
        '$scheme. Open Backup and run one by hand.',
      );
    }

    final encrypted = scheme == 'keyring-v1';
    if (encrypted && !await hasCachedKey) {
      return _note('Automatic backup needs the passphrase once — open Backup.');
    }

    final notes = <String>[];
    if (due('last_backup', autoInterval)) {
      final engine = await this.engine(encrypted: encrypted);
      if (engine == null) return null;
      try {
        notes.add(await backupNow(engine));
      } catch (e) {
        return _note('Automatic backup failed: $e');
      }
    }
    if (due('last_verify', verifyInterval)) {
      final engine = await this.engine(encrypted: encrypted);
      if (engine != null) {
        final problem = await verifyNow(engine);
        notes.add(problem == null ? 'verified' : 'verify problem: $problem');
      }
    }
    if (notes.isEmpty) return null;
    return _note(notes.join(' · '));
  }

  Future<String> _note(String text) async {
    try {
      await saveConfig({'last_auto_note': text, 'last_auto_at': nowUtcIso()});
    } catch (_) {}
    return text;
  }
}
