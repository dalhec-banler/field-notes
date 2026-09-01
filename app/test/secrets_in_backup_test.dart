import 'dart:convert';
import 'dart:io';

import 'package:field_notes/backup/backup_crypto.dart';
import 'package:field_notes/backup/backup_engine.dart';
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:flutter_test/flutter_test.dart';

/// Identification keys ride only inside the sealed body of an ENCRYPTED
/// backup — that is how a paired computer inherits the phone's Pl@ntNet
/// and AI account — and never appear anywhere in a plain one.
void main() {
  late FieldNotesDb db;
  late Directory work;

  setUp(() {
    db = FieldNotesDb.forTesting();
    work = Directory.systemTemp.createTempSync('secrets');
  });

  tearDown(() async {
    await db.close();
    work.deleteSync(recursive: true);
  });

  const secrets = {
    'plantnet_api_key': '2b10PLANTNETSECRET',
    'llm_api_key': 'sk-ant-VERYSECRET',
    'llm_provider': 'anthropic',
  };

  Future<String> everythingOnDisk(Directory dir) async {
    final b = StringBuffer();
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      b.write(latin1.decode(f.readAsBytesSync(), allowInvalid: true));
    }
    return b.toString();
  }

  test(
    'encrypted: keys round-trip through the sealed body, not the disk',
    () async {
      final salt = BackupEngine.newSalt();
      final cipher = await PassphraseCipher.fromPassphrase(
        'correct horse',
        salt,
        memoryKiB: 256,
        iterations: 1,
      );
      final target = Directory('${work.path}/t')..createSync();
      final engine = BackupEngine(
        db,
        DirectoryTarget(target),
        cipher,
        envelopeExtra: {'salt': base64Encode(salt)},
        secretsProvider: () async => secrets,
      );
      await engine.backup();

      final onDisk = await everythingOnDisk(target);
      expect(onDisk, isNot(contains('VERYSECRET')));
      expect(onDisk, isNot(contains('PLANTNETSECRET')));

      final reader = BackupEngine(
        db,
        DirectoryTarget(target),
        cipher,
        secretsProvider: () async => {},
      );
      await reader.restore(
        dbOut: File('${work.path}/r/db.sqlite'),
        mediaRestoreDir: Directory('${work.path}/r/media'),
      );
      expect(reader.restoredSecrets, secrets);
    },
  );

  test('plain: keys are never written, even when offered', () async {
    final target = Directory('${work.path}/p')..createSync();
    final engine = BackupEngine(
      db,
      DirectoryTarget(target),
      const PlainCipher(),
      secretsProvider: () async => secrets,
    );
    await engine.backup();
    final onDisk = await everythingOnDisk(target);
    expect(onDisk, isNot(contains('VERYSECRET')));
    expect(onDisk, isNot(contains('plantnet_api_key')));

    await engine.restore(
      dbOut: File('${work.path}/r2/db.sqlite'),
      mediaRestoreDir: Directory('${work.path}/r2/media'),
    );
    expect(engine.restoredSecrets, isNull);
  });
}
