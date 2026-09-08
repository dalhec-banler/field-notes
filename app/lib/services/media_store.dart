import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';

/// Photo storage per spec §4.10: keep the full-resolution original, write a
/// 1600 px long-edge working copy and a 320 px thumbnail, record sha256 for
/// dedupe. Layout: `<documents>/media/photos/YYYY/MM/<id>.jpg` (+ .work.jpg,
/// .thumb.jpg alongside).
class MediaStore {
  MediaStore(this.db);

  final FieldNotesDb db;

  /// File bytes that arrived by sync under this device's own layout —
  /// the photo's original plus its working copy and thumbnail, or the
  /// audio file — and return (local, thumb). The row is updated by the
  /// caller, quietly: paths are this device's business (D-028).
  Future<(String, String?)> placeBytes(
    Uint8List bytes, {
    required String id,
    required String mediaType,
    required String when,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final ym = when.length >= 7
        ? when.substring(0, 7).split('-')
        : ['0000', '00'];
    if (mediaType == 'audio') {
      final dir = Directory(p.join(docs.path, 'media', 'audio', ym[0], ym[1]))
        ..createSync(recursive: true);
      final dest = p.join(dir.path, '$id.m4a');
      File(dest).writeAsBytesSync(bytes);
      return (dest, null);
    }
    final dir = Directory(p.join(docs.path, 'media', 'photos', ym[0], ym[1]))
      ..createSync(recursive: true);
    final originalPath = p.join(dir.path, '$id.jpg');
    File(originalPath).writeAsBytesSync(bytes);
    try {
      final derived = await compute(_deriveCopies, bytes);
      File(p.join(dir.path, '$id.work.jpg')).writeAsBytesSync(derived.working);
      final thumbPath = p.join(dir.path, '$id.thumb.jpg');
      File(thumbPath).writeAsBytesSync(derived.thumb);
      return (originalPath, thumbPath);
    } catch (_) {
      // Not an image we can decode: the original is still the record.
      return (originalPath, null);
    }
  }

  Future<MediaData> savePhoto(
    Uint8List originalBytes, {
    required String propertyId,
    required String createdBy,
    double? lat,
    double? lng,
    double? headingDeg,
    String? capturedAt,
  }) async {
    final id = newId();
    final now = nowUtcIso();
    final when = capturedAt ?? now;

    final docs = await getApplicationDocumentsDirectory();
    final ym = when.substring(0, 7).split('-'); // YYYY-MM
    final dir = Directory(p.join(docs.path, 'media', 'photos', ym[0], ym[1]));
    dir.createSync(recursive: true);

    final originalPath = p.join(dir.path, '$id.jpg');
    final workPath = p.join(dir.path, '$id.work.jpg');
    final thumbPath = p.join(dir.path, '$id.thumb.jpg');

    File(originalPath).writeAsBytesSync(originalBytes);
    final derived = await compute(_deriveCopies, originalBytes);
    File(workPath).writeAsBytesSync(derived.working);
    File(thumbPath).writeAsBytesSync(derived.thumb);

    final row = MediaCompanion.insert(
      id: id,
      propertyId: propertyId,
      mediaType: 'photo',
      localPath: Value(originalPath),
      thumbPath: Value(thumbPath),
      sha256: Value(sha256.convert(originalBytes).toString()),
      bytes: Value(originalBytes.length),
      width: Value(derived.width),
      height: Value(derived.height),
      capturedAt: Value(when),
      lat: Value(lat),
      lng: Value(lng),
      headingDeg: Value(headingDeg),
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
    );
    await db.into(db.media).insert(row);
    return (await (db.select(
      db.media,
    )..where((m) => m.id.equals(id))).getSingle());
  }

  Future<void> linkTo(
    String mediaId, {
    required String propertyId,
    required String entityType,
    required String entityId,
    String role = 'attachment',
  }) async {
    await db
        .into(db.mediaLinks)
        .insert(
          MediaLinksCompanion.insert(
            id: newId(),
            propertyId: propertyId,
            mediaId: mediaId,
            entityType: entityType,
            entityId: entityId,
            role: Value(role),
            createdAt: nowUtcIso(),
          ),
        );
  }
}

/// Voice notes (spec §3.5): the audio file is kept as-is under
/// `<documents>/media/audio/YYYY/MM/<id>.m4a`, hashed for the backup's
/// content addressing. Never discarded in favour of the transcript.
extension MediaStoreAudio on MediaStore {
  Future<MediaData> saveAudio(
    File source, {
    required String propertyId,
    required String createdBy,
    double? lat,
    double? lng,
    String? capturedAt,
    int? durationMs,
    String? transcript,
  }) async {
    final id = newId();
    final now = nowUtcIso();
    final when = capturedAt ?? now;
    final docs = await getApplicationDocumentsDirectory();
    final ym = when.substring(0, 7).split('-');
    final dir = Directory(p.join(docs.path, 'media', 'audio', ym[0], ym[1]));
    dir.createSync(recursive: true);
    final ext = p.extension(source.path).isEmpty
        ? '.m4a'
        : p.extension(source.path);
    final dest = p.join(dir.path, '$id$ext');
    final bytes = source.readAsBytesSync();
    File(dest).writeAsBytesSync(bytes);
    await db
        .into(db.media)
        .insert(
          MediaCompanion.insert(
            id: id,
            propertyId: propertyId,
            mediaType: 'audio',
            localPath: Value(dest),
            sha256: Value(sha256.convert(bytes).toString()),
            bytes: Value(bytes.length),
            durationMs: Value(durationMs),
            transcript: Value(transcript),
            capturedAt: Value(when),
            lat: Value(lat),
            lng: Value(lng),
            createdBy: createdBy,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return (await (db.select(
      db.media,
    )..where((m) => m.id.equals(id))).getSingle());
  }
}

class _Derived {
  _Derived(this.working, this.thumb, this.width, this.height);
  final Uint8List working;
  final Uint8List thumb;
  final int width;
  final int height;
}

_Derived _deriveCopies(Uint8List original) {
  final decoded = img.decodeImage(original);
  if (decoded == null) {
    // Undecodable image: keep the original as-is for both copies.
    return _Derived(original, original, 0, 0);
  }
  final oriented = img.bakeOrientation(decoded);
  img.Image scaleTo(int longEdge) {
    if (oriented.width <= longEdge && oriented.height <= longEdge) {
      return oriented;
    }
    return oriented.width >= oriented.height
        ? img.copyResize(oriented, width: longEdge)
        : img.copyResize(oriented, height: longEdge);
  }

  final working = img.encodeJpg(scaleTo(1600), quality: 85);
  final thumb = img.encodeJpg(scaleTo(320), quality: 75);
  return _Derived(
    Uint8List.fromList(working),
    Uint8List.fromList(thumb),
    oriented.width,
    oriented.height,
  );
}
