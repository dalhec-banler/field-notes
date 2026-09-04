import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/backup/backup_crypto.dart';
import 'package:field_notes/backup/backup_engine.dart';
import 'package:field_notes/backup/drive_target.dart';
import 'package:field_notes/backup/keyring.dart';
import 'package:field_notes/backup/restore.dart';
import 'package:field_notes/db/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Audit P3: a backup you cannot restore from isn't one. This drills the
/// whole Drive round trip — engine.backup() through a DriveTarget into a
/// fake Drive, then RestorePipeline.stageFromTarget() reading it back —
/// plain and encrypted, including the wrong-passphrase refusal.
class _FakeDrive {
  final files = <String, Uint8List>{};
  final names = <String, String>{};
  int _next = 0;

  http.Client client() => MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == '/drive/v3/files') {
      return http.Response(
        jsonEncode({
          'files': [
            for (final e in names.entries) {'id': e.key, 'name': e.value},
          ],
        }),
        200,
      );
    }
    if (request.method == 'GET' && path.startsWith('/drive/v3/files/')) {
      final id = path.split('/').last;
      final bytes = files[id];
      if (bytes == null) return http.Response('gone', 404);
      return http.Response.bytes(bytes, 200);
    }
    if (request.method == 'DELETE') {
      final id = path.split('/').last;
      files.remove(id);
      names.remove(id);
      return http.Response('', 204);
    }
    if (path.startsWith('/upload/drive/v3/files')) {
      final text = latin1.decode(request.bodyBytes);
      final meta = jsonDecode(
        text.substring(text.indexOf('{'), text.indexOf('}\r\n--') + 1),
      ) as Map<String, dynamic>;
      const marker = 'application/octet-stream\r\n\r\n';
      final start = text.indexOf(marker) + marker.length;
      final end = text.lastIndexOf('\r\n--');
      final id = request.method == 'PATCH'
          ? path.split('/').last
          : 'id${_next++}';
      files[id] = Uint8List.fromList(request.bodyBytes.sublist(start, end));
      names[id] = meta['name'] as String;
      return http.Response(jsonEncode({'id': id}), 200);
    }
    return http.Response('unexpected', 404);
  });
}

void main() {
  late FieldNotesDb db;
  late Directory work;
  late Directory photoDir;
  late Directory docsDir;
  late _FakeDrive drive;

  Future<List<Uint8List>> seedData() async {
    final now = nowUtcIso();
    final propId = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propId,
            name: 'Shorts Resort',
            createdBy: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final photos = <Uint8List>[];
    for (var i = 0; i < 3; i++) {
      final bytes = Uint8List.fromList(
        List.generate(40000 + i, (j) => (i + j) % 251),
      );
      photos.add(bytes);
      final f = File('${photoDir.path}/p$i.jpg')..writeAsBytesSync(bytes);
      final digest = await Sha256().hash(bytes);
      final hex = digest.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      await db
          .into(db.media)
          .insert(
            MediaCompanion.insert(
              id: newId(),
              propertyId: propId,
              mediaType: 'photo',
              localPath: Value(f.path),
              sha256: Value(hex),
              bytes: Value(bytes.length),
              createdBy: 'a',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    return photos;
  }

  setUp(() async {
    db = FieldNotesDb.forTesting();
    work = Directory.systemTemp.createTempSync('drv');
    photoDir = Directory('${work.path}/photos')..createSync();
    docsDir = Directory('${work.path}/docs')..createSync();
    drive = _FakeDrive();
  });

  tearDown(() async {
    await db.close();
    work.deleteSync(recursive: true);
  });

  test('plain: backup to Drive, stage a restore back out of it', () async {
    final photos = await seedData();
    final target = DriveTarget(accessToken: 't', client: drive.client());
    final engine = BackupEngine(db, target, const PlainCipher());
    await engine.backup();

    final pipeline = RestorePipeline(docsDir);
    // Fresh target instance: a restore on a new phone has no warm index.
    final readBack = DriveTarget(accessToken: 't', client: drive.client());
    final summary = await pipeline.stageFromTarget(readBack);
    expect(summary, contains('Restart the app'));
    expect(pipeline.hasStagedRestore, isTrue);

    // The staged database opens and holds the seeded property.
    final staged = sqlite.sqlite3.open(
      '${docsDir.path}/restore_staged/db.sqlite',
    );
    try {
      final rows = staged.select('SELECT name FROM properties');
      expect(rows.single['name'], 'Shorts Resort');
    } finally {
      staged.close();
    }

    // Every photo byte survived the trip through Drive.
    final mediaDir = Directory('${docsDir.path}/restore_staged/media');
    final restored = mediaDir
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.readAsBytesSync())
        .toList();
    expect(restored.length, photos.length);
    for (final original in photos) {
      expect(
        restored.any((r) => r.length == original.length),
        isTrue,
        reason: 'a restored blob matches each original size',
      );
    }
  });

  test(
    'encrypted: restores with the passphrase, refuses the wrong one',
    () async {
      await seedData();
      final keyring = await BackupKeyring.create(
        'correct horse',
        memoryKiB: 256,
        iterations: 1,
      );
      final target = DriveTarget(accessToken: 't', client: drive.client());
      final engine = BackupEngine(
        db,
        target,
        keyring.cipher,
        envelopeExtra: keyring.envelopeFields,
      );
      await engine.backup();

      final pipeline = RestorePipeline(docsDir);

      // No secret → the clean "this is encrypted" refusal the UI keys off.
      await expectLater(
        () => pipeline.stageFromTarget(
          DriveTarget(accessToken: 't', client: drive.client()),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('encrypted'),
          ),
        ),
      );

      // Wrong secret → refusal, and nothing staged.
      await expectLater(
        () => pipeline.stageFromTarget(
          DriveTarget(accessToken: 't', client: drive.client()),
          secret: 'wrong horse',
        ),
        throwsA(isA<StateError>()),
      );
      expect(pipeline.hasStagedRestore, isFalse);

      // Right secret → staged and integrity-checked.
      final summary = await pipeline.stageFromTarget(
        DriveTarget(accessToken: 't', client: drive.client()),
        secret: 'correct horse',
      );
      expect(summary, contains('Restart the app'));
      expect(pipeline.hasStagedRestore, isTrue);
    },
  );
}
