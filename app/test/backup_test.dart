import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/backup_crypto.dart';
import 'package:field_notes/backup/backup_engine.dart';
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FieldNotesDb db;
  late Directory work;
  late Directory targetDir;
  late Directory photoDir;

  // Fast KDF params for tests only; production uses the defaults.
  Future<PassphraseCipher> testCipher(String pass, List<int> salt) =>
      PassphraseCipher.fromPassphrase(pass, salt,
          memoryKiB: 256, iterations: 1);

  Future<String> seedData() async {
    final now = nowUtcIso();
    final propId = newId();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
          id: propId,
          name: 'Shorts Resort',
          createdBy: 'a',
          createdAt: now,
          updatedAt: now,
        ));
    // Two "photos" on disk with recorded hashes.
    for (var i = 0; i < 2; i++) {
      final bytes = Uint8List.fromList(
          List.generate(50000 + i, (j) => (i + j) % 251));
      final f = File('${photoDir.path}/p$i.jpg')..writeAsBytesSync(bytes);
      final digest = await Sha256().hash(bytes);
      final hex = digest.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      await db.into(db.media).insert(MediaCompanion.insert(
            id: newId(),
            propertyId: propId,
            mediaType: 'photo',
            localPath: Value(f.path),
            sha256: Value(hex),
            bytes: Value(bytes.length),
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ));
    }
    return propId;
  }

  setUp(() async {
    db = FieldNotesDb.forTesting();
    work = Directory.systemTemp.createTempSync('bk');
    targetDir = Directory('${work.path}/target')..createSync();
    photoDir = Directory('${work.path}/photos')..createSync();
  });

  tearDown(() async {
    await db.close();
    work.deleteSync(recursive: true);
  });

  for (final encrypted in [false, true]) {
    group(encrypted ? 'encrypted' : 'convenience (plain)', () {
      test('backup → restore round-trips DB and photos', () async {
        await seedData();
        final salt = BackupEngine.newSalt();
        final cipher = encrypted
            ? await testCipher('correct horse', salt)
            : const PlainCipher();
        final engine = BackupEngine(
            db, DirectoryTarget(targetDir), cipher,
            envelopeExtra: encrypted ? {'salt': base64Encode(salt)} : null);

        final summary = await engine.backup();
        expect(summary, contains('2 new photos'));

        // Restore into a fresh location (the factory-reset scenario).
        final restoreDb = File('${work.path}/restore/db.sqlite');
        final restoreMedia = Directory('${work.path}/restore/media');
        final result = await engine.restore(
            dbOut: restoreDb, mediaRestoreDir: restoreMedia);
        expect(result, contains('2 photos'));

        final copy = FieldNotesDb.fromFile(restoreDb);
        final props = await copy.select(copy.properties).get();
        expect(props.single.name, 'Shorts Resort');
        final restoredMedia = await copy.select(copy.media).get();
        expect(restoredMedia.length, 2);
        await copy.close();

        // Restored blob bytes match originals.
        for (final m in restoredMedia) {
          final blob = File('${restoreMedia.path}/${m.sha256}.bin');
          expect(blob.existsSync(), isTrue);
          final original = File(m.localPath!).readAsBytesSync();
          expect(blob.readAsBytesSync(), original);
        }
      });

      test('second backup uploads only the delta', () async {
        await seedData();
        final salt = BackupEngine.newSalt();
        final cipher = encrypted
            ? await testCipher('correct horse', salt)
            : const PlainCipher();
        final engine = BackupEngine(db, DirectoryTarget(targetDir), cipher,
            envelopeExtra: encrypted ? {'salt': base64Encode(salt)} : null);
        await engine.backup();
        final second = await engine.backup();
        expect(second, contains('Generation 2'));
        expect(second, contains('0 new photos'));
        expect(second, contains('2 unchanged'));
      });

      test('verify passes on a healthy backup', () async {
        await seedData();
        final salt = BackupEngine.newSalt();
        final cipher = encrypted
            ? await testCipher('correct horse', salt)
            : const PlainCipher();
        final engine = BackupEngine(db, DirectoryTarget(targetDir), cipher,
            envelopeExtra: encrypted ? {'salt': base64Encode(salt)} : null);
        await engine.backup();
        expect(await engine.verify(), isNull);
      });
    });
  }

  test('wrong passphrase fails cleanly, corrupts nothing (spec §11.10)',
      () async {
    await seedData();
    final salt = BackupEngine.newSalt();
    final good = await testCipher('correct horse', salt);
    final engine = BackupEngine(db, DirectoryTarget(targetDir), good,
        envelopeExtra: {'salt': base64Encode(salt)});
    await engine.backup();

    final bad = await testCipher('battery staple', salt);
    final badEngine = BackupEngine(db, DirectoryTarget(targetDir), bad,
        envelopeExtra: {'salt': base64Encode(salt)});
    expect(() => badEngine.readManifestBody(), throwsA(anything));

    // The stored backup is untouched and still restores with the right key.
    final restoreDb = File('${work.path}/restore/db.sqlite');
    await engine.restore(
        dbOut: restoreDb,
        mediaRestoreDir: Directory('${work.path}/restore/media'));
    expect(restoreDb.existsSync(), isTrue);
  });

  test('tampered blob fails verification', () async {
    await seedData();
    final salt = BackupEngine.newSalt();
    final cipher = await testCipher('correct horse', salt);
    final engine = BackupEngine(db, DirectoryTarget(targetDir), cipher,
        envelopeExtra: {'salt': base64Encode(salt)});
    await engine.backup();

    // Flip bytes in every stored blob.
    final blobRoot = Directory('${targetDir.path}/fieldnotes/blobs');
    for (final f in blobRoot.listSync(recursive: true).whereType<File>()) {
      final bytes = f.readAsBytesSync();
      bytes[bytes.length ~/ 2] ^= 0xFF;
      f.writeAsBytesSync(bytes);
    }
    expect(await engine.verify(), isNotNull);
  });

  test('encrypted blob names leak nothing (HMAC, not sha256)', () async {
    await seedData();
    final salt = BackupEngine.newSalt();
    final cipher = await testCipher('correct horse', salt);
    final engine = BackupEngine(db, DirectoryTarget(targetDir), cipher,
        envelopeExtra: {'salt': base64Encode(salt)});
    await engine.backup();

    final media = await db.select(db.media).get();
    final names = Directory('${targetDir.path}/fieldnotes/blobs')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path.split('/').last)
        .toList();
    for (final m in media) {
      expect(names.any((n) => n.contains(m.sha256!)), isFalse,
          reason: 'blob name must not contain the plaintext sha256');
    }
  });
}
