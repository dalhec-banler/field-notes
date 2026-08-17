import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Encryption layer for backups (spec §11.4, D-011).
///
/// Two modes:
/// - [PassphraseCipher]: Argon2id(passphrase) → master key; whole-file
///   XChaCha20-Poly1305 AEAD; blob names are HMAC-SHA256(key, sha256) so
///   filenames leak nothing.
/// - [PlainCipher]: convenience mode (D-010) — no encryption, plaintext
///   names. Same backup structure.
abstract class BackupCipher {
  /// 'plain' or 'argon2id-xchacha20'; recorded in the manifest.
  String get scheme;

  Future<Uint8List> seal(Uint8List plaintext);
  Future<Uint8List> open(Uint8List sealed);

  /// Storage name for a media blob with the given content sha256 (hex).
  Future<String> blobName(String sha256Hex);

  /// File extension for sealed files.
  String get ext;
}

class PlainCipher implements BackupCipher {
  const PlainCipher();

  @override
  String get scheme => 'plain';

  @override
  String get ext => '';

  @override
  Future<Uint8List> seal(Uint8List plaintext) async => plaintext;

  @override
  Future<Uint8List> open(Uint8List sealed) async => sealed;

  @override
  Future<String> blobName(String sha256Hex) async => sha256Hex;
}

class PassphraseCipher implements BackupCipher {
  PassphraseCipher._(this._key);

  final SecretKey _key;

  static final _aead = Xchacha20.poly1305Aead();

  /// Argon2id tuned to roughly ~1 s on a midrange phone (spec §11.4).
  /// Parameters are stored in the manifest header so they can be raised later
  /// without breaking old backups.
  static Argon2id kdf({int memoryKiB = 65536, int iterations = 3}) => Argon2id(
        parallelism: 2,
        memory: memoryKiB,
        iterations: iterations,
        hashLength: 32,
      );

  static Future<PassphraseCipher> fromPassphrase(
    String passphrase,
    List<int> salt, {
    int memoryKiB = 65536,
    int iterations = 3,
  }) async {
    final key = await kdf(memoryKiB: memoryKiB, iterations: iterations)
        .deriveKeyFromPassword(password: passphrase, nonce: salt);
    return PassphraseCipher._(key);
  }

  @override
  String get scheme => 'argon2id-xchacha20';

  @override
  String get ext => '.enc';

  @override
  Future<Uint8List> seal(Uint8List plaintext) async {
    final box = await _aead.encrypt(plaintext, secretKey: _key);
    // nonce (24) ‖ ciphertext ‖ mac (16)
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
    final plain = await _aead.decrypt(box, secretKey: _key);
    return Uint8List.fromList(plain);
  }

  @override
  Future<String> blobName(String sha256Hex) async {
    final mac = await Hmac.sha256()
        .calculateMac(utf8.encode(sha256Hex), secretKey: _key);
    return mac.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
