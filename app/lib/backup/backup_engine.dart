import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/database.dart';
import '../id/id_keys.dart';
import 'backup_crypto.dart';
import 'target.dart';

/// Incremental, content-addressed backup (spec §11).
///
/// Layout under the target root:
///   fieldnotes/manifest.json            — plaintext envelope: scheme + salt
///   `fieldnotes/db/<generation>.sqlite[.enc]`
///   `fieldnotes/blobs/<name[0:2]>/<name>[.enc]` — write-once media
///
/// The manifest envelope is never encrypted (it holds the salt needed to
/// derive the key); the sensitive inner manifest (blob inventory, property
/// names) is sealed with the same cipher as everything else.
/// A backup that cannot be trusted as written — a photo that doesn't match
/// its recorded fingerprint, or an inventory the store can't satisfy.
/// Loud on purpose: a restore that quietly drops evidence is worse than one
/// that stops (external audit 2026-09-04, findings 3 and 4).
class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BackupEngine {
  BackupEngine(
    this.db,
    this.target,
    this.cipher, {
    this.envelopeExtra,
    Future<Map<String, String>> Function()? secretsProvider,
  }) : _secretsProvider = secretsProvider ?? IdKeys.exportForBackup;

  final FieldNotesDb db;
  final BackupTarget target;
  final BackupCipher cipher;

  /// The identification keys (Pl@ntNet, the user's AI account). They ride
  /// inside the SEALED manifest body of an encrypted backup — so a paired
  /// computer that restores with the passphrase gets them too — and are
  /// left out of a plain backup entirely, where they would sit in clear on
  /// Drive. Never in the database, never in an export.
  final Future<Map<String, String>> Function() _secretsProvider;

  /// Set by [restore] when the manifest carried keys; the caller stores
  /// them in the keystore.
  Map<String, String>? restoredSecrets;

  /// Extra plaintext envelope fields — KDF salts and wrapped keys for
  /// keyring-v1, or a bare salt for direct passphrase mode. Never secret.
  final Map<String, Object?>? envelopeExtra;

  static const root = 'fieldnotes';
  static const generationsToKeep = 5;

  static List<int> newSalt() =>
      List<int>.generate(16, (_) => Random.secure().nextInt(256));

  /// Runs a backup. Returns a human-readable summary.
  Future<String> backup() async {
    // 1. Consistent DB snapshot via VACUUM INTO (spec §11.7).
    final tmpDir = Directory.systemTemp.createTempSync('fnbk');
    final tmp = File('${tmpDir.path}/dump.sqlite');
    await db.customStatement("VACUUM INTO '${tmp.path.replaceAll("'", "''")}'");
    final dbBytes = tmp.readAsBytesSync();

    // The inventory is read from the SNAPSHOT, not the running database
    // (external audit 2026-09-04, finding 6): a photo deleted while the
    // dump uploaded used to leave a manifest whose inventory disagreed
    // with the very database it described — and verification passed
    // because the inventory was simply empty.
    final snapshotMedia =
        <({String id, String sha, int? bytes, String? path})>[];
    final snapshot = sqlite3.open(tmp.path);
    try {
      for (final r in snapshot.select(
        'SELECT id, sha256, bytes, local_path FROM media '
        'WHERE deleted_at IS NULL AND sha256 IS NOT NULL',
      )) {
        snapshotMedia.add((
          id: r['id'] as String,
          sha: r['sha256'] as String,
          bytes: r['bytes'] as int?,
          path: r['local_path'] as String?,
        ));
      }
    } finally {
      snapshot.dispose();
    }
    tmpDir.deleteSync(recursive: true);

    // 2. Determine generation number from the previous manifest.
    final previous = await _readManifest();
    final generation = ((previous?['generation'] as int?) ?? 0) + 1;

    // 3. Upload DB dump.
    final dbPath = '$root/db/$generation.sqlite${cipher.ext}';
    await target.write(dbPath, await cipher.seal(dbBytes));

    // 4. Media blobs: write-once by content hash (spec §11.3). Only blobs
    //    absent from the target are uploaded — this is the incremental part.
    var uploaded = 0;
    var skipped = 0;
    var missing = 0;
    final inventory = <Map<String, Object?>>[];
    for (final m in snapshotMedia) {
      final name = await cipher.blobName(m.sha);
      final blobPath = '$root/blobs/${name.substring(0, 2)}/$name${cipher.ext}';
      inventory.add({
        'media_id': m.id,
        'sha256': m.sha,
        'blob': blobPath,
        'bytes': m.bytes,
      });
      if (await target.exists(blobPath)) {
        skipped++;
        continue;
      }
      final src = m.path;
      if (src == null || !File(src).existsSync()) {
        missing++;
        continue;
      }
      await target.write(
        blobPath,
        await cipher.seal(File(src).readAsBytesSync()),
      );
      uploaded++;
    }

    // 5. Manifest: plaintext envelope + sealed body.
    final body = {
      'generation': generation,
      'created_at': nowUtcIso(),
      'db_path': dbPath,
      'db_bytes': dbBytes.length,
      'blobs': inventory,
      // Keys only where the body is sealed: a plain backup never carries them.
      if (cipher.scheme != 'plain') 'secrets': await _secretsProvider(),
    };
    final envelope = {
      'app': 'field_notes',
      'format': 1,
      'scheme': cipher.scheme,
      ...?envelopeExtra,
      'generation': generation,
      'created_at': body['created_at'],
      'body': base64Encode(
        await cipher.seal(Uint8List.fromList(utf8.encode(jsonEncode(body)))),
      ),
    };
    await target.write(
      '$root/manifest.json',
      Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
    );

    // 6. Keep the last N DB generations (spec §11.7). Blobs are never
    //    touched here — a separate, user-initiated prune handles those.
    await _pruneGenerations(keep: generationsToKeep);

    return 'Generation $generation: DB ${_fmt(dbBytes.length)}, '
        '$uploaded new photo${uploaded == 1 ? '' : 's'}, $skipped unchanged'
        '${missing > 0 ? ', $missing missing locally' : ''}';
  }

  Future<void> _pruneGenerations({required int keep}) async {
    final dumps = await target.list('$root/db');
    final byGen = <int, String>{};
    for (final path in dumps) {
      final name = path.split('/').last;
      final gen = int.tryParse(name.split('.').first);
      if (gen != null) byGen[gen] = path;
    }
    final gens = byGen.keys.toList()..sort();
    for (final gen in gens.take(gens.length > keep ? gens.length - keep : 0)) {
      try {
        await target.delete(byGen[gen]!);
      } catch (_) {
        // A stubborn old dump costs disk, not safety.
      }
    }
  }

  Future<Map<String, Object?>?> _readManifest() async {
    if (!await target.exists('$root/manifest.json')) return null;
    final envelope = jsonDecode(
      utf8.decode(await target.read('$root/manifest.json')),
    ) as Map<String, dynamic>;
    return envelope;
  }

  /// Reads and unseals the manifest body. Throws on wrong passphrase.
  Future<Map<String, Object?>> readManifestBody() async {
    final envelope = await _readManifest();
    if (envelope == null) throw StateError('No backup found at target');
    final sealed = base64Decode(envelope['body'] as String);
    return jsonDecode(utf8.decode(await cipher.open(sealed)))
        as Map<String, Object?>;
  }

  /// Restore (spec §11.9): DB first — the app is usable immediately — then
  /// media blobs into [mediaRestoreDir], remapped onto their original paths
  /// where recorded.
  /// Photos the last restore expected and the store did not hold. Empty
  /// after a complete restore.
  List<String> lastMissingMedia = const [];

  Future<String> restore({
    required File dbOut,
    required Directory mediaRestoreDir,

    /// Accept a backup whose store is missing some photos. Off by default:
    /// the caller has to choose the lossy path out loud.
    bool allowMissingMedia = false,
  }) async {
    final body = await readManifestBody();
    final dbBytes = await cipher.open(
      await target.read(body['db_path'] as String),
    );
    dbOut.parent.createSync(recursive: true);
    dbOut.writeAsBytesSync(dbBytes);
    final secrets = body['secrets'];
    if (secrets is Map) {
      restoredSecrets = secrets.map((k, v) => MapEntry('$k', '$v'));
    }

    var restored = 0;
    final missing = <String>[];
    final blobs = (body['blobs'] as List).cast<Map<String, dynamic>>();
    for (final blob in blobs) {
      final path = blob['blob'] as String;
      final want = '${blob['sha256']}';
      if (!await target.exists(path)) {
        // Named, not shrugged off (audit finding 4): a photo the manifest
        // promised and the store doesn't hold is a hole in the evidence.
        missing.add(want);
        continue;
      }
      final plain = await cipher.open(await target.read(path));
      // A valid AEAD tag proves the bytes were sealed with this key — NOT
      // that they are the photo this record expects. Two blobs under one
      // key can be swapped with no key at all (audit finding 3), so the
      // content hash decides identity.
      final got = await _sha256Hex(plain);
      if (got != want) {
        throw BackupException(
          'Backup is corrupt: a photo does not match its recorded '
          'fingerprint (expected $want, found $got). Nothing was restored '
          'from it.',
        );
      }
      final out = File('${mediaRestoreDir.path}/$want.bin');
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(plain);
      restored++;
    }
    if (missing.isNotEmpty && !allowMissingMedia) {
      throw BackupException(
        'This backup is incomplete: ${missing.length} of ${blobs.length} '
        'photos are missing from the store. Restore was stopped so nothing '
        'is silently lost — restore again allowing gaps if you want the '
        'records without them.',
      );
    }
    lastMissingMedia = List.unmodifiable(missing);
    final gap = missing.isEmpty ? '' : ' · ${missing.length} missing';
    return 'Restored DB (${_fmt(dbBytes.length)}) and $restored photos$gap';
  }

  /// Weekly verification (spec §11.8): decrypt the manifest and one blob,
  /// check the content hash. Returns null on success, else the problem.
  Future<String?> verify() async {
    try {
      final body = await readManifestBody();
      final blobs = (body['blobs'] as List).cast<Map<String, dynamic>>();
      if (blobs.isEmpty) return null;
      final pick = blobs[Random().nextInt(blobs.length)];
      final path = pick['blob'] as String;
      if (!await target.exists(path)) return 'Blob missing: $path';
      final plain = await cipher.open(await target.read(path));
      final hash = await _sha256Hex(plain);
      if (hash != pick['sha256']) return 'Hash mismatch on $path';
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<String> _sha256Hex(Uint8List bytes) async {
    final digest = await Sha256().hash(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _fmt(int b) => b > 1 << 20
      ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(b / 1024).toStringAsFixed(0)} KB';
}
