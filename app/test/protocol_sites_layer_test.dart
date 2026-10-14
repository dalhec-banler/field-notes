import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:field_notes/export/map_plate.dart';
import 'package:field_notes/export/web_mercator.dart';
import 'package:field_notes/map/layers/map_layers.dart';
import 'package:field_notes/map/map_markers.dart';
import 'package:field_notes/map/map_screen.dart' show mapLayerIds;
import 'package:field_notes/map/protocol_site_glyph.dart';
import 'package:flutter_test/flutter_test.dart';

/// Monitoring sites on the map (D-033, D-038 item 11): the station glyph
/// is one painter every surface asks; the plate prints it only when its
/// switch is on, and the phone's layers sheet carries the switch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String poly(List<List<double>> lnglat) => jsonEncode({
    'type': 'Polygon',
    'coordinates': [
      [...lnglat, lnglat.first],
    ],
  });

  final boundary = poly([
    [-98.06, 31.05],
    [-98.03, 31.05],
    [-98.03, 31.07],
    [-98.06, 31.07],
  ]);

  const plot = ProtocolSiteMark(
    id: 'site-1',
    protocolId: 'proto-1',
    name: 'Plot 1',
    lat: 31.062,
    lng: -98.042,
  );
  const retired = ProtocolSiteMark(
    id: 'site-2',
    protocolId: 'proto-1',
    name: 'Old line',
    lat: 31.055,
    lng: -98.055,
    retiredOn: '2026-06-01',
  );

  final subject = PlateSubject(
    propertyName: 'Test Place',
    boundaryGeojson: boundary,
    sites: const [plot, retired],
  );

  Future<Uint8List> solidTile(int argb) async {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      const ui.Rect.fromLTWH(0, 0, 256, 256),
      ui.Paint()..color = ui.Color(argb),
    );
    final img = await rec.endRecording().toImage(256, 256);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  /// Raw RGBA of a PNG, with its width.
  Future<(Uint8List, int)> rgba(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    final w = frame.image.width;
    frame.image.dispose();
    codec.dispose();
    return (data!.buffer.asUint8List(), w);
  }

  /// How many pixels differ inside a square window centred on (cx, cy).
  int differing(
    (Uint8List, int) a,
    (Uint8List, int) b,
    int cx,
    int cy, {
    int half = 24,
  }) {
    var n = 0;
    for (var y = cy - half; y <= cy + half; y++) {
      for (var x = cx - half; x <= cx + half; x++) {
        final i = (y * a.$2 + x) * 4;
        if (i < 0 || i + 3 >= a.$1.length) continue;
        for (var k = 0; k < 4; k++) {
          if (a.$1[i + k] != b.$1[i + k]) {
            n++;
            break;
          }
        }
      }
    }
    return n;
  }

  test(
    'the plate leaves sites off unless asked, and prints them when it is',
    () {
      expect(const PlateLayers().protocolSites, isFalse);
      expect(
        const PlateLayers().copyWith(protocolSites: true).protocolSites,
        isTrue,
      );
      expect(
        const PlateLayers(protocolSites: true)
            .copyWith(zones: false)
            .protocolSites,
        isTrue,
      );
      expect(subject.sites.map((s) => s.name), ['Plot 1', 'Old line']);
    },
  );

  test(
    'with the switch on, the stake is ink on the plate; off, it is not',
    () async {
      final tile = await solidTile(0xFF6A7B5A);
      final plate = MapPlate(fetchTile: (z, x, y) async => tile);
      const scale = 2.0;
      final off = await plate.render(subject, maxWidth: 800, maxHeight: 600);
      final on = await plate.render(
        subject,
        layers: const PlateLayers(protocolSites: true),
        maxWidth: 800,
        maxHeight: 600,
      );
      // The boundary frames both, so the two rasters line up pixel for pixel.
      expect(on.width, off.width);
      expect(on.height, off.height);
      expect(on.bounds.north, off.bounds.north);

      final a = await rgba(off.png);
      final b = await rgba(on.png);
      final frame = PlateFrame(bounds: on.bounds, zoom: on.zoom);
      final (sx, sy) = frame.toPlate(plot.lat, plot.lng);
      final (rx, ry) = frame.toPlate(retired.lat, retired.lng);

      // Something is drawn at each stake…
      expect(
        differing(a, b, (sx * scale).round(), (sy * scale).round()),
        greaterThan(40),
      );
      expect(
        differing(a, b, (rx * scale).round(), (ry * scale).round()),
        greaterThan(40),
      );
      // …and nothing changes in a corner no site is near.
      expect(differing(a, b, 40, on.height - 120, half: 12), 0);

      // The legend names the layer only when it drew.
      expect(off.legend.map((e) => e.$2), isNot(contains('Monitoring site')));
      expect(on.legend.map((e) => e.$2), contains('Monitoring site'));
    },
  );

  test(
    'the glyph is one painter: retired draws lighter, never nothing',
    () async {
      Future<(Uint8List, int)> glyph({required bool retiredSite}) async {
        final rec = ui.PictureRecorder();
        final c = ui.Canvas(rec);
        c.drawRect(
          const ui.Rect.fromLTWH(0, 0, 54, 54),
          ui.Paint()..color = const ui.Color(0xFF6A7B5A),
        );
        paintProtocolSite(
          c,
          const ui.Offset(27, 27),
          r: 12,
          retired: retiredSite,
        );
        final img = await rec.endRecording().toImage(54, 54);
        final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        img.dispose();
        return (data!.buffer.asUint8List(), 54);
      }

      final active = await glyph(retiredSite: false);
      final faded = await glyph(retiredSite: true);
      int at((Uint8List, int) px, int x, int y, int k) =>
          px.$1[(y * px.$2 + x) * 4 + k];
      // The stake dot at the centre is ink on the active glyph…
      expect(at(active, 27, 27, 0), lessThan(0x40));
      // …and visibly lighter (blended toward the imagery) when retired.
      expect(at(faded, 27, 27, 0), greaterThan(at(active, 27, 27, 0)));
      // The arm crosses the square's side: ink east of centre at 1.5 r.
      expect(at(active, 27 + 15, 27, 0), lessThan(0x60));
      // Paper inside the square, between the dot and the side.
      expect(at(active, 27 + 7, 27 + 7, 0), greaterThan(0xE0));

      // The phone's bitmaps come out as PNGs of the right box.
      final png = await protocolSiteMarker();
      expect(png.sublist(1, 4), utf8.encode('PNG'));
      final (_, w) = await rgba(png);
      expect(w, 54 * 3);
    },
  );

  test(
    'the phone layers sheet round-trips the switch and knows the layer id',
    () {
      const all = LayerVisibility();
      expect(all.protocolSites, isTrue);
      expect(all.isOn(MapLayerKind.protocolSites), isTrue);
      final off = all.copyWith(protocolSites: false);
      expect(off.isOn(MapLayerKind.protocolSites), isFalse);
      expect(off.isOn(MapLayerKind.photoPoints), isTrue);
      expect(
        off.copyWith(protocolSites: true).isOn(MapLayerKind.protocolSites),
        isTrue,
      );
      expect(mapLayerIds[MapLayerKind.protocolSites], ['protocol-sites-pt']);

      final set = MapLayerSet.of(
        propertyName: 'x',
        sites: const [plot],
        visibility: off,
      );
      expect(set.sites, hasLength(1));
      expect(
        set.visible.map((l) => l.kind),
        isNot(contains(MapLayerKind.protocolSites)),
      );
    },
  );
}
