import 'dart:io';

import 'package:field_notes/id/send_copy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// What leaves for an identification (hard rule 3): downsized, EXIF gone —
/// proven by putting GPS into a JPEG and reading the copy back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('sendcopy'));
  tearDown(() => work.deleteSync(recursive: true));

  File jpegWithGps({int width = 2400, int height = 1800}) {
    final im = img.Image(width: width, height: height);
    img.fill(im, color: img.ColorRgb8(90, 110, 70));
    im.exif.imageIfd['Make'] = 'TestCam';
    im.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(31, 1);
    im.exif.gpsIfd['GPSLongitude'] = img.IfdValueRational(98, 1);
    im.exif.gpsIfd['GPSLatitudeRef'] = 'N';
    final f = File('${work.path}/original.jpg')
      ..writeAsBytesSync(img.encodeJpg(im, quality: 95));
    return f;
  }

  test('the send copy is smaller and carries no EXIF at all', () async {
    final original = jpegWithGps();
    // Sanity: the original really does carry GPS.
    final origDecoded = img.decodeJpg(original.readAsBytesSync())!;
    expect(origDecoded.exif.gpsIfd.isEmpty, isFalse);

    final copies = await identificationSendCopies([original]);
    expect(copies, hasLength(1));
    final bytes = copies.first.readAsBytesSync();
    final decoded = img.decodeJpg(bytes)!;
    expect(decoded.width, 1600);
    expect(decoded.exif.gpsIfd.isEmpty, isTrue,
        reason: 'GPS must not survive into the send copy');
    expect(decoded.exif.imageIfd['Make'], isNull);
    expect(bytes.length, lessThan(original.lengthSync()));
    cleanupSendCopies(copies);
    expect(copies.first.existsSync(), isFalse);
  });

  test('a small photo is not upscaled, but still loses its EXIF', () async {
    final original = jpegWithGps(width: 800, height: 600);
    final copies = await identificationSendCopies([original]);
    final decoded = img.decodeJpg(copies.first.readAsBytesSync())!;
    expect(decoded.width, 800);
    expect(decoded.exif.gpsIfd.isEmpty, isTrue);
    cleanupSendCopies(copies);
  });

  test('an undecodable file is skipped, never sent as-is', () async {
    final junk = File('${work.path}/junk.jpg')
      ..writeAsBytesSync([1, 2, 3, 4, 5]);
    final good = jpegWithGps(width: 900, height: 700);
    final copies = await identificationSendCopies([junk, good]);
    expect(copies, hasLength(1));
    cleanupSendCopies(copies);
  });
}
