import 'dart:io';
import 'dart:typed_data';

import 'package:field_notes/map/area_downloader.dart';
import 'package:field_notes/map/mbtiles_store.dart';
import 'package:field_notes/map/pmtiles_reader.dart';
import 'package:flutter_test/flutter_test.dart';

const _lampasas =
    '/Users/austinnelsen/Desktop/Field Notes/docs/basemap/lampasas.pmtiles';

void main() {
  final haveArchive = File(_lampasas).existsSync();

  group('PmTilesReader against the real Lampasas archive', () {
    test('parses the header: bounds cover the property, zooms sane',
        () async {
      final reader =
          await PmTilesReader.open(FileRangeSource(File(_lampasas)));
      final b = reader.header.bounds;
      // Extracted with bbox -98.75,30.65,-97.75,31.45.
      expect(b[0], lessThanOrEqualTo(-98.18));
      expect(b[2], greaterThanOrEqualTo(-98.18));
      expect(b[1], lessThanOrEqualTo(31.06));
      expect(b[3], greaterThanOrEqualTo(31.06));
      expect(reader.header.maxZoom, greaterThanOrEqualTo(10));
      reader.close();
    });

    test('fetches a tile over the property and it is gzip MVT', () async {
      final reader =
          await PmTilesReader.open(FileRangeSource(File(_lampasas)));
      final z = 10;
      final x = TileMath.lonToX(-98.18, z);
      final y = TileMath.latToY(31.06, z);
      final tile = await reader.getTile(z, x, y);
      expect(tile, isNotNull);
      // Stored MVT is gzip-compressed (magic 1f 8b).
      expect(tile![0], 0x1f);
      expect(tile[1], 0x8b);
      reader.close();
    });

    test('returns null far outside the archive bounds', () async {
      final reader =
          await PmTilesReader.open(FileRangeSource(File(_lampasas)));
      // Tokyo at z10 is not in a Lampasas County extract.
      final tile = await reader.getTile(
          10, TileMath.lonToX(139.7, 10), TileMath.latToY(35.7, 10));
      expect(tile, isNull);
      reader.close();
    });
  }, skip: !haveArchive);

  group('tile math', () {
    test('hilbert tile ids are unique and ordered per zoom', () {
      final ids = <int>{};
      for (var x = 0; x < 8; x++) {
        for (var y = 0; y < 8; y++) {
          ids.add(zxyToTileId(3, x, y));
        }
      }
      expect(ids.length, 64);
      expect(ids.reduce((a, b) => a < b ? a : b), 21); // acc(3) = 1+4+16
      expect(ids.reduce((a, b) => a > b ? a : b), 21 + 63);
    });

    test('cover produces the expected pyramid', () {
      final tiles = TileMath.cover(-98.20, 31.05, -98.17, 31.07,
          minZ: 0, maxZ: 10);
      // One tile per low zoom at minimum; every zoom present.
      expect(tiles.where((t) => t.$1 == 0).length, 1);
      expect(tiles.where((t) => t.$1 == 10), isNotEmpty);
      // The z10 tile containing the point is covered.
      expect(
          tiles.contains(
              (10, TileMath.lonToX(-98.18, 10), TileMath.latToY(31.06, 10))),
          isTrue);
    });
  });

  group('MbTilesStore', () {
    test('round-trips tiles with TMS flip and accumulates', () {
      final dir = Directory.systemTemp.createTempSync('mb');
      final store =
          MbTilesStore.open(File('${dir.path}/t.mbtiles'), create: true);
      final data = Uint8List.fromList([1, 2, 3, 4]);
      store.putTile(10, 236, 425, data);
      expect(store.getTile(10, 236, 425), data);
      expect(store.getTile(10, 236, 426), isNull);
      // Accumulate a second area without clobbering.
      store.putTile(12, 900, 1700, data);
      expect(store.tileCount, 2);
      store.setMetadata({'format': 'pbf', 'maxzoom': '15'});
      expect(store.metadata['format'], 'pbf');
      store.close();
      dir.deleteSync(recursive: true);
    });
  });

  group('full area capture from the local archive (offline drill)', () {
    test('downloads a small crop into MBTiles', () async {
      final dir = Directory.systemTemp.createTempSync('cap');
      // Redirect the target into the temp dir via a store opened directly:
      // exercise the pipeline pieces the downloader composes.
      final reader =
          await PmTilesReader.open(FileRangeSource(File(_lampasas)));
      final store =
          MbTilesStore.open(File('${dir.path}/cap.mbtiles'), create: true);
      final tiles = TileMath.cover(-98.20, 31.05, -98.17, 31.07,
          minZ: 8, maxZ: reader.header.maxZoom.clamp(8, 12));
      var written = 0;
      for (final (z, x, y) in tiles) {
        final data = await reader.getTile(z, x, y);
        if (data != null) {
          store.putTile(z, x, y, data);
          written++;
        }
      }
      expect(written, greaterThan(3));
      // Served-back tile matches the source archive byte for byte.
      final z = 10;
      final x = TileMath.lonToX(-98.18, z);
      final y = TileMath.latToY(31.06, z);
      expect(store.getTile(z, x, y), await reader.getTile(z, x, y));
      store.close();
      reader.close();
      dir.deleteSync(recursive: true);
    });
  }, skip: !haveArchive);

  test('estimate caps zoom to keep tile counts sane', () {
    // A whole county at z15 would blow past the cap; estimate backs off.
    final (n, maxZ) = AreaDownloader.estimate(-98.75, 30.65, -97.75, 31.45);
    expect(n, lessThanOrEqualTo(AreaDownloader.maxTiles + 1));
    expect(maxZ, inInclusiveRange(12, 15));
    // A small property crop keeps full z15 detail.
    final (n2, maxZ2) = AreaDownloader.estimate(-98.20, 31.05, -98.17, 31.07);
    expect(maxZ2, 15);
    expect(n2, lessThan(200));
  });
}
