import 'dart:convert';

import '../services/secret_store.dart';

/// Spec §11.4: the master/data key lives in platform secure storage
/// (Android Keystore) so routine backups don't prompt for the passphrase;
/// the passphrase is needed only at setup and restore.
///
/// What's cached is the raw 32-byte data key — the thing that actually
/// decrypts blobs. The wrapped copies in `backup_config.json` and the
/// manifest envelope are unaffected; clearing the cache just means the next
/// backup asks for the passphrase again.
class BackupKeyCache {
  BackupKeyCache({SecretStore? store, String? name})
    : _storage = store ?? SecretStore(),
      _key = name == null ? _backupKey : 'shared_data_key_v1_$name';

  /// A shared property's data key (D-031) is cached under its own name,
  /// beside — never instead of — the backup's.
  BackupKeyCache.forSharedProperty(String propertyId, {SecretStore? store})
    : this(store: store, name: propertyId);

  final SecretStore _storage;
  final String _key;
  static const _backupKey = 'backup_data_key_v1';

  Future<List<int>?> read() async {
    try {
      final b64 = await _storage.read(_key);
      if (b64 == null) return null;
      return base64Decode(b64);
    } catch (_) {
      return null; // no secure storage on this platform (host tests)
    }
  }

  Future<void> write(List<int> dataKey) async {
    try {
      await _storage.write(_key, base64Encode(dataKey));
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      await _storage.delete(_key);
    } catch (_) {}
  }
}
