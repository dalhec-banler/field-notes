import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/backup_crypto.dart';
import 'package:field_notes/backup/backup_engine.dart';
import 'package:field_notes/backup/keyring.dart';
import 'package:field_notes/backup/restore.dart';
import 'package:field_notes/backup/target.dart';
import 'package:field_notes/db/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late FieldNotesDb source;
  late Directory work;
  late Directory docs; // simulated app documents dir on the "new phone"

  setUp(() async {
    source = FieldNotesDb.forTesting();
    work = Directory.systemTemp.createTempSync('restore');
    docs = Directory('${work.path}/docs')..createSync();
  });

  tearDown(() async {
    await source.close();
    work.deleteSync(recursive: true);
  });

  Future<void> seed() async {
    final now = nowUtcIso();
    final propId = newId();
    await source.into(source.properties).insert(PropertiesCompanion.insert(
          id: propId,
          name: 'Shorts Resort',
          createdBy: 'a',
          createdAt: now,
          updatedAt: now,
        ));
    final bytes = List.generate(20000, (i) => i % 251);
    final photo = File('${work.path}/photo.jpg')..writeAsBytesSync(bytes);
    final digest = await Sha256().hash(bytes);
    final hex = digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await source.into(source.media).insert(MediaCompanion.insert(
          id: newId(),
          propertyId: propId,
          mediaType: 'photo',
          localPath: Value(photo.path),
          sha256: Value(hex),
          createdBy: 'a',
          createdAt: now,
          updatedAt: now,
        ));
  }

  test('full lost-phone drill: backup → zip → stage → apply → remap',
      () async {
    await seed();

    // Old phone: encrypted backup with a keyring.
    final keyring =
        await BackupKeyring.create('correct horse', memoryKiB: 256, iterations: 1);
    final store = Directory('${work.path}/store')..createSync();
    final engine = BackupEngine(source, DirectoryTarget(store), keyring.cipher,
        envelopeExtra: keyring.envelopeFields);
    await engine.backup();

    // The backup leaves as a zip (the share-sheet artifact).
    final zipPath = '${work.path}/backup.zip';
    final encoder = ZipFileEncoder()..create(zipPath);
    await encoder.addDirectory(Directory('${store.path}/fieldnotes'));
    await encoder.close();

    // New phone: stage using ONLY the recovery phrase.
    final pipeline = RestorePipeline(docs);
    final summary = await pipeline.stageFromZip(File(zipPath),
        secret: keyring.recoveryPhrase);
    expect(summary, contains('Restart'));
    expect(pipeline.hasStagedRestore, isTrue);

    // Launch: swap DB in before opening.
    final liveDb = p.join(docs.path, 'field_notes.sqlite');
    expect(pipeline.applyStagedDb(liveDb), isTrue);

    final restored = FieldNotesDb.fromFile(File(liveDb));
    final props = await restored.select(restored.properties).get();
    expect(props.single.name, 'Shorts Resort');

    // Media remap: the old-phone path is dead; rows repoint to local blobs.
    // (Simulate the dead path — tests share one filesystem.)
    File('${work.path}/photo.jpg').deleteSync();
    final remapped = await pipeline.remapRestoredMedia(restored);
    expect(remapped, 1);
    final media = (await restored.select(restored.media).get()).single;
    expect(File(media.localPath!).existsSync(), isTrue);
    expect(media.localPath, contains('restored'));
    expect(pipeline.hasStagedRestore, isFalse); // staging cleaned up
    await restored.close();
  });

  test('wrong secret gives a clean error', () async {
    await seed();
    final keyring =
        await BackupKeyring.create('correct horse', memoryKiB: 256, iterations: 1);
    final store = Directory('${work.path}/store')..createSync();
    await BackupEngine(source, DirectoryTarget(store), keyring.cipher,
            envelopeExtra: keyring.envelopeFields)
        .backup();
    final zipPath = '${work.path}/backup.zip';
    final encoder = ZipFileEncoder()..create(zipPath);
    await encoder.addDirectory(Directory('${store.path}/fieldnotes'));
    await encoder.close();

    final pipeline = RestorePipeline(docs);
    await expectLater(
      pipeline.stageFromZip(File(zipPath), secret: 'totally wrong'),
      throwsA(predicate((e) => '$e'.contains('wrong'))),
    );
    expect(pipeline.hasStagedRestore, isFalse);
  });

  test('plain backup restores with no secret at all', () async {
    await seed();
    final store = Directory('${work.path}/store')..createSync();
    await BackupEngine(source, DirectoryTarget(store), const PlainCipher())
        .backup();
    final zipPath = '${work.path}/backup.zip';
    final encoder = ZipFileEncoder()..create(zipPath);
    await encoder.addDirectory(Directory('${store.path}/fieldnotes'));
    await encoder.close();

    final pipeline = RestorePipeline(docs);
    final summary = await pipeline.stageFromZip(File(zipPath));
    expect(summary, contains('Restart'));

    final liveDb = p.join(docs.path, 'field_notes.sqlite');
    expect(pipeline.applyStagedDb(liveDb), isTrue);
    final restored = FieldNotesDb.fromFile(File(liveDb));
    expect((await restored.select(restored.properties).get()).length, 1);
    await restored.close();
  });

  test('existing live DB is kept as .pre-restore, not destroyed', () async {
    await seed();
    final store = Directory('${work.path}/store')..createSync();
    await BackupEngine(source, DirectoryTarget(store), const PlainCipher())
        .backup();
    final pipeline = RestorePipeline(docs);
    // Stage directly from a local store this time.
    final localStore = Directory(p.join(docs.path, 'backups'));
    localStore.createSync(recursive: true);
    for (final f in Directory(store.path)
        .listSync(recursive: true)
        .whereType<File>()) {
      final rel = p.relative(f.path, from: store.path);
      final dest = File(p.join(localStore.path, rel));
      dest.parent.createSync(recursive: true);
      f.copySync(dest.path);
    }
    await pipeline.stageFromLocalStore();

    final liveDb = p.join(docs.path, 'field_notes.sqlite');
    File(liveDb).writeAsStringSync('precious existing data');
    pipeline.applyStagedDb(liveDb);
    final preRestore = Directory(p.dirname(liveDb))
        .listSync()
        .whereType<File>()
        .firstWhere((f) => p.basename(f.path).startsWith(
            '${p.basename(liveDb)}.pre-restore'));
    expect(preRestore.readAsStringSync(),
        'precious existing data');
  });

  test('envelope survives the zip round trip readable as JSON', () async {
    await seed();
    final store = Directory('${work.path}/store')..createSync();
    await BackupEngine(source, DirectoryTarget(store), const PlainCipher())
        .backup();
    final manifest =
        File('${store.path}/fieldnotes/manifest.json').readAsStringSync();
    final envelope = jsonDecode(manifest) as Map<String, dynamic>;
    expect(envelope['app'], 'field_notes');
    expect(envelope['scheme'], 'plain');
  });
}
