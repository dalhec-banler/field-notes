import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:drift/drift.dart';

import '../db/database.dart';
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
class BackupEngine {
  BackupEngine(this.db, this.target, this.cipher, {this.envelopeExtra});

  final FieldNotesDb db;
  final BackupTarget target;
  final BackupCipher cipher;

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
    final tmp = File(
        '${Directory.systemTemp.createTempSync('fnbk').path}/dump.sqlite');
    await db.customStatement(
        "VACUUM INTO '${tmp.path.replaceAll("'", "''")}'");
    final dbBytes = tmp.readAsBytesSync();
    tmp.parent.deleteSync(recursive: true);

    // 2. Determine generation number from the previous manifest.
    final previous = await _readManifest();
    final generation = ((previous?['generation'] as int?) ?? 0) + 1;

    // 3. Upload DB dump.
    final dbPath = '$root/db/$generation.sqlite${cipher.ext}';
    await target.write(dbPath, await cipher.seal(dbBytes));

    // 4. Media blobs: write-once by content hash (spec §11.3). Only blobs
    //    absent from the target are uploaded — this is the incremental part.
    final media = await (db.select(db.media)
          ..where((m) => m.deletedAt.isNull())
          ..where((m) => m.sha256.isNotNull()))
        .get();
    var uploaded = 0;
    var skipped = 0;
    var missing = 0;
    final inventory = <Map<String, Object?>>[];
    for (final m in media) {
      final name = await cipher.blobName(m.sha256!);
      final blobPath = '$root/blobs/${name.substring(0, 2)}/$name${cipher.ext}';
      inventory.add({
        'media_id': m.id,
        'sha256': m.sha256,
        'blob': blobPath,
        'bytes': m.bytes,
      });
      if (await target.exists(blobPath)) {
        skipped++;
        continue;
      }
      final src = m.localPath;
      if (src == null || !File(src).existsSync()) {
        missing++;
        continue;
      }
      await target.write(
          blobPath, await cipher.seal(File(src).readAsBytesSync()));
      uploaded++;
    }

    // 5. Manifest: plaintext envelope + sealed body.
    final body = {
      'generation': generation,
      'created_at': nowUtcIso(),
      'db_path': dbPath,
      'db_bytes': dbBytes.length,
      'blobs': inventory,
    };
    final envelope = {
      'app': 'field_notes',
      'format': 1,
      'scheme': cipher.scheme,
      ...?envelopeExtra,
      'generation': generation,
      'created_at': body['created_at'],
      'body': base64Encode(
          await cipher.seal(Uint8List.fromList(utf8.encode(jsonEncode(body))))),
    };
    await target.write('$root/manifest.json',
        Uint8List.fromList(utf8.encode(jsonEncode(envelope))));

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
    final envelope =
        jsonDecode(utf8.decode(await target.read('$root/manifest.json')))
            as Map<String, dynamic>;
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
  Future<String> restore({
    required File dbOut,
    required Directory mediaRestoreDir,
  }) async {
    final body = await readManifestBody();
    final dbBytes = await cipher.open(await target.read(body['db_path'] as String));
    dbOut.parent.createSync(recursive: true);
    dbOut.writeAsBytesSync(dbBytes);

    var restored = 0;
    final blobs = (body['blobs'] as List).cast<Map<String, dynamic>>();
    for (final blob in blobs) {
      final path = blob['blob'] as String;
      if (!await target.exists(path)) continue;
      final plain = await cipher.open(await target.read(path));
      final out = File(
          '${mediaRestoreDir.path}/${blob['sha256']}.bin');
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(plain);
      restored++;
    }
    return 'Restored DB (${_fmt(dbBytes.length)}) and $restored photos';
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
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String _fmt(int b) => b > 1 << 20
      ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(b / 1024).toStringAsFixed(0)} KB';
}
