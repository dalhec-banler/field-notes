import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Spec §11.4: the master/data key lives in platform secure storage
/// (Android Keystore) so routine backups don't prompt for the passphrase;
/// the passphrase is needed only at setup and restore.
///
/// What's cached is the raw 32-byte data key — the thing that actually
/// decrypts blobs. The wrapped copies in `backup_config.json` and the
/// manifest envelope are unaffected; clearing the cache just means the next
/// backup asks for the passphrase again.
class BackupKeyCache {
  BackupKeyCache({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'backup_data_key_v1';

  Future<List<int>?> read() async {
    try {
      final b64 = await _storage.read(key: _key);
      if (b64 == null) return null;
      return base64Decode(b64);
    } catch (_) {
      return null; // no secure storage on this platform (host tests)
    }
  }

  Future<void> write(List<int> dataKey) async {
    try {
      await _storage.write(key: _key, value: base64Encode(dataKey));
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}
