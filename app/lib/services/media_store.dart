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
    return (await (db.select(db.media)..where((m) => m.id.equals(id)))
        .getSingle());
  }

  Future<void> linkTo(
    String mediaId, {
    required String propertyId,
    required String entityType,
    required String entityId,
    String role = 'attachment',
  }) async {
    await db.into(db.mediaLinks).insert(MediaLinksCompanion.insert(
          id: newId(),
          propertyId: propertyId,
          mediaId: mediaId,
          entityType: entityType,
          entityId: entityId,
          role: Value(role),
          createdAt: nowUtcIso(),
        ));
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
