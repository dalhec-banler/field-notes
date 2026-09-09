import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Where secrets live: the platform keystore, and when the keystore
/// refuses this build, a file inside the app's own sandbox.
///
/// The desk is an ad-hoc-signed sandboxed build (no Apple team yet) and
/// the macOS keychain answers every write with errSecMissingEntitlement;
/// the Drive grant has worked around that since D-021. The identification
/// keys and the passphrase cache did not — a write failed silently and
/// the key was gone at the next launch (Austin, 2026-09-09: "it's not
/// there any more"). One store, one rule, for all three: keychain first;
/// on refusal, `secrets.json` in Application Support, which is under the
/// same sandbox protection as the database itself. Signing with a team
/// and a keychain entitlement moves everything back, no code change.
class SecretStore {
  SecretStore({FlutterSecureStorage? keystore, File? file})
    : _keystore = keystore ?? const FlutterSecureStorage(),
      _fileOverride = file;

  final FlutterSecureStorage _keystore;
  final File? _fileOverride;
  bool _keystoreBroken = false;

  Future<File> _file() async {
    if (_fileOverride != null) return _fileOverride;
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/secrets.json');
  }

  Future<Map<String, String>> _readFile() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return {};
      return (jsonDecode(await f.readAsString()) as Map).map(
        (k, v) => MapEntry(k as String, v as String),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeFile(Map<String, String> m) async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(m), flush: true);
    } catch (_) {
      // No writable support directory either (host tests): nothing kept.
    }
  }

  Future<String?> read(String key) async {
    if (!_keystoreBroken) {
      try {
        final v = await _keystore.read(key: key);
        if (v != null) return v;
      } catch (_) {
        _keystoreBroken = true;
      }
    }
    return (await _readFile())[key];
  }

  Future<void> write(String key, String value) async {
    if (!_keystoreBroken) {
      try {
        await _keystore.write(key: key, value: value);
        return;
      } catch (_) {
        _keystoreBroken = true;
      }
    }
    final m = await _readFile();
    m[key] = value;
    await _writeFile(m);
  }

  Future<void> delete(String key) async {
    if (!_keystoreBroken) {
      try {
        await _keystore.delete(key: key);
      } catch (_) {
        _keystoreBroken = true;
      }
    }
    final m = await _readFile();
    if (m.remove(key) != null) await _writeFile(m);
  }
}
