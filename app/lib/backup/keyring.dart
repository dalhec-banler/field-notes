import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:cryptography/cryptography.dart';

import 'backup_crypto.dart';

/// Keyring (spec §11.4 + §11.6): a random 32-byte data key encrypts
/// everything; the data key is wrapped twice — once by a passphrase-derived
/// key, once by a key derived from a 12-word BIP-39 recovery phrase. Either
/// path unlocks the backup; the passphrase can change without re-encrypting
/// any blob.
class BackupKeyring {
  BackupKeyring._({
    required this.cipher,
    required this.envelopeFields,
    this.recoveryPhrase,
  });

  /// Cipher sealed with the raw data key.
  final DataKeyCipher cipher;

  /// Goes into the backup manifest envelope (and local config): salts and
  /// wrapped copies of the data key. Safe to store in plaintext.
  final Map<String, Object?> envelopeFields;

  /// Present only at creation time — shown once for the recovery kit.
  final String? recoveryPhrase;

  static final _aead = Xchacha20.poly1305Aead();

  static List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => Random.secure().nextInt(256));

  static Future<SecretKey> _derive(
    String secret,
    List<int> salt, {
    int memoryKiB = 65536,
    int iterations = 3,
  }) =>
      PassphraseCipher.kdf(memoryKiB: memoryKiB, iterations: iterations)
          .deriveKeyFromPassword(password: secret, nonce: salt);

  static Future<Uint8List> _wrap(List<int> dataKey, SecretKey wrapKey) async {
    final box = await _aead.encrypt(dataKey, secretKey: wrapKey);
    return Uint8List.fromList(
        [...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<List<int>> _unwrap(
      Uint8List wrapped, SecretKey wrapKey) async {
    final box = SecretBox(
      wrapped.sublist(24, wrapped.length - 16),
      nonce: wrapped.sublist(0, 24),
      mac: Mac(wrapped.sublist(wrapped.length - 16)),
    );
    return _aead.decrypt(box, secretKey: wrapKey);
  }

  /// Creates a new keyring. Show [recoveryPhrase] to the user exactly once.
  static Future<BackupKeyring> create(
    String passphrase, {
    int memoryKiB = 65536,
    int iterations = 3,
  }) async {
    final dataKey = _randomBytes(32);
    final mnemonic = bip39.generateMnemonic(); // 12 words, 128-bit entropy

    final saltPass = _randomBytes(16);
    final saltRec = _randomBytes(16);
    final passKey = await _derive(passphrase, saltPass,
        memoryKiB: memoryKiB, iterations: iterations);
    final recKey = await _derive(mnemonic, saltRec,
        memoryKiB: memoryKiB, iterations: iterations);

    final fields = {
      'scheme': 'keyring-v1',
      'kdf': {'memory_kib': memoryKiB, 'iterations': iterations},
      'salt_pass': base64Encode(saltPass),
      'salt_rec': base64Encode(saltRec),
      'wrap_pass': base64Encode(await _wrap(dataKey, passKey)),
      'wrap_rec': base64Encode(await _wrap(dataKey, recKey)),
    };
    return BackupKeyring._(
      cipher: DataKeyCipher(SecretKey(dataKey)),
      envelopeFields: fields,
      recoveryPhrase: mnemonic,
    );
  }

  /// Unlocks with the everyday passphrase.
  static Future<BackupKeyring> unlockWithPassphrase(
    Map<String, dynamic> fields,
    String passphrase,
  ) =>
      _unlock(fields, passphrase, 'salt_pass', 'wrap_pass');

  /// Unlocks with the 12-word recovery phrase alone (spec §11.6).
  static Future<BackupKeyring> unlockWithRecoveryPhrase(
    Map<String, dynamic> fields,
    String mnemonic,
  ) =>
      _unlock(fields, mnemonic.trim().toLowerCase(), 'salt_rec', 'wrap_rec');

  static Future<BackupKeyring> _unlock(
    Map<String, dynamic> fields,
    String secret,
    String saltField,
    String wrapField,
  ) async {
    final kdf = (fields['kdf'] as Map?) ?? const {};
    final wrapKey = await _derive(
      secret,
      base64Decode(fields[saltField] as String),
      memoryKiB: (kdf['memory_kib'] as int?) ?? 65536,
      iterations: (kdf['iterations'] as int?) ?? 3,
    );
    final dataKey =
        await _unwrap(base64Decode(fields[wrapField] as String), wrapKey);
    return BackupKeyring._(
      cipher: DataKeyCipher(SecretKey(dataKey)),
      envelopeFields: Map<String, Object?>.from(fields),
    );
  }
}

/// AEAD cipher over a raw data key — the working cipher behind keyring-v1.
class DataKeyCipher implements BackupCipher {
  DataKeyCipher(this._key);

  final SecretKey _key;
  static final _aead = Xchacha20.poly1305Aead();

  @override
  String get scheme => 'keyring-v1';

  @override
  String get ext => '.enc';

  @override
  Future<Uint8List> seal(Uint8List plaintext) async {
    final box = await _aead.encrypt(plaintext, secretKey: _key);
    return Uint8List.fromList(
        [...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  @override
  Future<Uint8List> open(Uint8List sealed) async {
    if (sealed.length < 24 + 16) {
      throw const FormatException('sealed data too short');
    }
    final box = SecretBox(
      sealed.sublist(24, sealed.length - 16),
      nonce: sealed.sublist(0, 24),
      mac: Mac(sealed.sublist(sealed.length - 16)),
    );
    return Uint8List.fromList(await _aead.decrypt(box, secretKey: _key));
  }

  @override
  Future<String> blobName(String sha256Hex) async {
    final mac = await Hmac.sha256()
        .calculateMac(utf8.encode(sha256Hex), secretKey: _key);
    return mac.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
