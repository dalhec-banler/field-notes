import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// What actually leaves the device for an identification (hard rule 3,
/// D-022): a downsized re-encode with the EXIF block cleared — no GPS, no
/// serial numbers — orientation baked into the pixels first so nothing
/// rotates. The originals never go anywhere.
///
/// This exists because the stored `.work.jpg` derivation keeps EXIF (the
/// image package copies it through resize and re-encode), and because the
/// capture flow identifies before anything is saved at all.
Future<List<File>> identificationSendCopies(List<File> photos) async {
  final dir = Directory.systemTemp.createTempSync('fn_id_send');
  final out = <File>[];
  for (var i = 0; i < photos.length; i++) {
    final bytes = await photos[i].readAsBytes();
    final derived = await compute(_deriveSendCopy, bytes);
    // A photo we can't decode is NOT sent as-is — rule 3 wins. Our own
    // camera and the work pipeline always produce decodable JPEGs.
    if (derived == null) continue;
    final f = File(p.join(dir.path, 'send_$i.jpg'));
    f.writeAsBytesSync(derived);
    out.add(f);
  }
  return out;
}

/// Delete the temp copies (and their directory) once the request is done.
void cleanupSendCopies(List<File> copies) {
  if (copies.isEmpty) return;
  try {
    copies.first.parent.deleteSync(recursive: true);
  } catch (_) {}
}

Uint8List? _deriveSendCopy(Uint8List original) {
  try {
    final decoded = img.decodeImage(original);
    if (decoded == null) return null;
    final oriented = img.bakeOrientation(decoded);
    final longEdge = oriented.width >= oriented.height
        ? oriented.width
        : oriented.height;
    final scaled = longEdge <= 1600
        ? oriented
        : (oriented.width >= oriented.height
              ? img.copyResize(oriented, width: 1600)
              : img.copyResize(oriented, height: 1600));
    // The point of the exercise: a fresh, empty EXIF block.
    scaled.exif = img.ExifData();
    return img.encodeJpg(scaled, quality: 85);
  } catch (_) {
    return null;
  }
}
