import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import '../map/record_ink.dart';
import '../services/diag.dart';
import 'web_mercator.dart';

part 'map_plate/models.dart';
part 'map_plate/fetch.dart';
part 'map_plate/paint.dart';
part 'map_plate/furniture.dart';
part 'map_plate/geometry.dart';

/// A map plate (D-024): the property's geometry composited over public
/// imagery into one raster the desk can preview, print, or hand to a
/// grantor. Our own renderer — maplibre_gl has no desktop platform — and
/// deliberately simple: tiles, polygons, points, lines, furniture.
///
/// Nothing here reads the database; the caller assembles a [PlateSubject]
/// so the renderer is host-testable with fabricated geometry and a fake
/// tile fetcher.

class MapPlate {
  MapPlate({required this.fetchTile, this.maxZoom = 16, this.concurrency = 6});

  final TileFetcher fetchTile;
  final int maxZoom;
  final int concurrency;

  /// Frames the subject, fetches imagery, draws everything. [maxWidth] and
  /// [maxHeight] bound the raster; the frame is whatever the bounds need at
  /// the chosen zoom, so the image is usually smaller than the maximum.
  Future<PlateResult> render(
    PlateSubject subject, {
    PlateLayers layers = const PlateLayers(),

    /// Species mode: only these species' records draw, each in its own
    /// ink; the legend names them. Null (or empty) = every record in its
    /// type colour, as before.
    List<PlateSpecies>? species,

    /// Removal plan (D-027): ONLY records flagged for removal draw, as
    /// numbered oxblood pins, in species-then-date order. The returned
    /// [PlateResult.numbered] is that order — the list beside the map.
    bool removalPlan = false,

    /// Frame this many zoom levels past the source's cache: tiles are
    /// upscaled into their quadrants. A poster framed at the source cap
    /// renders a few hundred pixels stretched to two feet — soft imagery
    /// and comically large furniture (2026-09-04).
    int overzoom = 0,
    double maxWidth = 1600,
    double maxHeight = 1100,
    String attribution = 'Imagery: USGS The National Map · Field Notes',
    double scale = 2,
  }) async {
    final bounds = frameBounds(subject, layers);
    final zoom = zoomFor(
      bounds,
      maxWidth,
      maxHeight,
      maxZoom: maxZoom + overzoom,
    );
    final frame = PlateFrame(bounds: bounds, zoom: zoom);

    final tiles = await _fetchAll(frame, srcMaxZoom: maxZoom);
    var missing = 0;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    // Supersample: imagery stops at 16, a plate wants pixels. Everything
    // is drawn in frame units under one transform, so ink and text come
    // out crisp and only the imagery is upsampled.
    canvas.scale(scale);
    final w = frame.width.toDouble();
    final h = frame.height.toDouble();
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w, h),
      ui.Paint()..color = ui.Color(PlateInk.paper),
    );

    // Imagery. Overzoomed frames draw a quadrant of the parent tile.
    for (final (tx, ty) in frame.tiles) {
      final entry = tiles[(tx, ty)];
      final (ox, oy) = frame.tileOrigin(tx, ty);
      if (entry == null) {
        missing++;
        _drawMissingTile(canvas, ox, oy);
        continue;
      }
      final (img, src) = entry;
      canvas.drawImageRect(
        img,
        src,
        ui.Rect.fromLTWH(ox, oy, tileSize, tileSize),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      img.dispose();
    }
    // A soft wash so ink reads on imagery.
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w, h),
      ui.Paint()..color = const ui.Color(0x1AF7F6F2),
    );

    final legend = <(int, String)>[];

    // Government overlays: one bbox-sized image each, drawn over the base.
    final mercBbox = _mercBboxOf(bounds);
    Future<void> overlay(String url, {double opacity = 1}) async {
      final img = await _fetchOverlayImage(url);
      if (img == null) return;
      canvas.drawImageRect(
        img,
        ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, w, h),
        ui.Paint()
          ..color = ui.Color.fromRGBO(0, 0, 0, opacity)
          ..filterQuality = ui.FilterQuality.medium,
      );
      img.dispose();
    }

    final ow = (frame.width).clamp(256, 2000).toInt();
    final oh = (frame.height * ow / frame.width).round().clamp(256, 2000);
    if (layers.soils) {
      await overlay(
        '$_soilsWms?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap'
        '&LAYERS=MapunitPoly&STYLES=&SRS=EPSG:3857&BBOX=$mercBbox'
        '&WIDTH=$ow&HEIGHT=$oh&FORMAT=image/png&TRANSPARENT=true',
        opacity: 0.9,
      );
      legend.add((0xFFB5652B, 'Soil map units · USDA-NRCS'));
    }
    if (layers.contours) {
      await overlay(
        '$_contoursExport?bbox=$mercBbox&bboxSR=3857&imageSR=3857'
        '&size=$ow,$oh&transparent=true&format=png32&f=image',
        opacity: 0.85,
      );
      legend.add((0xFF7A5C3B, 'Elevation contours · USGS'));
    }
    if (layers.hydro) {
      await overlay(
        '$_hydroExport?bbox=$mercBbox&bboxSR=3857&imageSR=3857'
        '&size=$ow,$oh&transparent=true&format=png32&f=image',
      );
      legend.add((0xFF2F5D8A, 'Hydrology · USGS NHD'));
    }

    // Zones.
    if (layers.zones) {
      for (var i = 0; i < subject.zones.length; i++) {
        final z = subject.zones[i];
        final color =
            _parseHex(z.colorHex) ??
            PlateInk.zoneFills[i % PlateInk.zoneFills.length];
        final path = _polygonPath(frame, z.geojson);
        if (path == null) continue;
        canvas.drawPath(
          path,
          ui.Paint()..color = ui.Color(color).withValues(alpha: 0.30),
        );
        canvas.drawPath(
          path,
          ui.Paint()
            ..color = ui.Color(color)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 2,
        );
        legend.add((color, z.name));
      }
    }

    // Boundary — white halo under oxblood so it holds on any imagery.
    if (layers.boundary && subject.boundaryGeojson != null) {
      final path = _polygonPath(frame, subject.boundaryGeojson!);
      if (path != null) {
        canvas.drawPath(
          path,
          ui.Paint()
            ..color = const ui.Color(0xCCFFFFFF)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 6,
        );
        canvas.drawPath(
          path,
          ui.Paint()
            ..color = ui.Color(PlateInk.oxblood)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 3,
        );
        legend.insert(0, (PlateInk.oxblood, 'Property boundary'));
      }
    }

    // Tracks.
    if (layers.tracks) {
      var drew = false;
      for (final t in subject.tracks) {
        final path = _linePath(frame, t.geojson);
        if (path == null) continue;
        canvas.drawPath(
          path,
          ui.Paint()
            ..color = const ui.Color(0xB3FFFFFF)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 5
            ..strokeCap = ui.StrokeCap.round,
        );
        canvas.drawPath(
          path,
          ui.Paint()
            ..color = ui.Color(PlateInk.ink)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeCap = ui.StrokeCap.round,
        );
        drew = true;
      }
      if (drew) legend.add((PlateInk.ink, 'Walked track'));
    }

    // Features.
    if (layers.features) {
      final seen = <String>{};
      for (final f in subject.features) {
        final geo = _decode(f.geojson);
        if (geo == null) continue;
        final color = switch (f.featureClass) {
          'problem' => PlateInk.oxblood,
          'infrastructure' => PlateInk.ink,
          _ => PlateInk.river,
        };
        switch (geo['type']) {
          case 'Point':
            final c = geo['coordinates'] as List;
            final (x, y) = frame.toPlate(
              (c[1] as num).toDouble(),
              (c[0] as num).toDouble(),
            );
            _drawFeatureMarker(canvas, x, y, f.featureClass, color);
          case 'LineString':
            final path = _linePath(frame, f.geojson);
            if (path != null) {
              canvas.drawPath(
                path,
                ui.Paint()
                  ..color = ui.Color(color)
                  ..style = ui.PaintingStyle.stroke
                  ..strokeWidth = 2.5,
              );
            }
          case 'Polygon':
            final path = _polygonPath(frame, f.geojson);
            if (path != null) {
              canvas.drawPath(
                path,
                ui.Paint()..color = ui.Color(color).withValues(alpha: 0.25),
              );
              canvas.drawPath(
                path,
                ui.Paint()
                  ..color = ui.Color(color)
                  ..style = ui.PaintingStyle.stroke
                  ..strokeWidth = 2,
              );
            }
        }
        final label = switch (f.featureClass) {
          'problem' => 'Problem feature',
          'infrastructure' => 'Infrastructure',
          _ => 'Natural feature',
        };
        if (seen.add(label)) legend.add((color, label));
      }
    }

    // Records — coincident points collapse to one badge with a count, so a
    // printed plate never hides records under each other.
    var overlapGroups = 0;
    final numbered = <PlateRecord>[];
    if (removalPlan) {
      // The contractor's map: what comes out, and nothing else.
      numbered.addAll(
        subject.records.where((r) => r.removal == 'flagged').toList()
          ..sort((a, b) {
            final bySpecies = (a.label ?? '~${a.type}').toLowerCase().compareTo(
              (b.label ?? '~${b.type}').toLowerCase(),
            );
            return bySpecies != 0
                ? bySpecies
                : (a.observedAt ?? '').compareTo(b.observedAt ?? '');
          }),
      );
      final index = {
        for (var i = 0; i < numbered.length; i++) numbered[i]: i + 1,
      };
      for (final g in groupOverlapping(frame, numbered)) {
        final (x, y) = g.$1;
        final members = g.$2..sort((a, b) => index[a]!.compareTo(index[b]!));
        final label = members.length == 1
            ? '${index[members.first]}'
            : '${index[members.first]}+${members.length - 1}';
        if (members.length > 1) overlapGroups++;
        _drawNumberBadge(canvas, x, y, label);
      }
      if (numbered.isNotEmpty) {
        legend.add((
          PlateInk.oxblood,
          'Flagged for removal · ${numbered.length}',
        ));
      }
      if (overlapGroups > 0) {
        legend.add((PlateInk.oxblood, '+n: more flagged at the same spot'));
      }
    } else if (layers.records && subject.records.isNotEmpty) {
      final speciesInk = (species == null || species.isEmpty)
          ? null
          : {for (final s in species) s.key: s.ink};
      // Species mode draws ONLY the chosen species — unchosen records
      // stay off the file entirely (fewer coordinates shipped).
      final source = speciesInk == null
          ? subject.records
          : [
              for (final r in subject.records)
                if (speciesInk.containsKey(r.label ?? '__type:${r.type}')) r,
            ];
      final groups = groupOverlapping(frame, source);
      final typesSeen = <String>{};
      final removalSeen = <String>{};
      for (final g in groups) {
        final (x, y) = g.$1;
        final members = g.$2;
        if (members.length == 1) {
          final r = members.first;
          _drawRecordMark(
            canvas,
            x,
            y,
            r.type,
            colorOverride: speciesInk?[r.label ?? '__type:${r.type}'],
          );
          if (r.removal != null) {
            _drawRemovalRing(canvas, x, y, flagged: r.removal == 'flagged');
            removalSeen.add(r.removal!);
          }
          if (speciesInk == null) typesSeen.add(r.type);
        } else {
          overlapGroups++;
          _drawCountBadge(canvas, x, y, members.length);
        }
      }
      if (speciesInk != null) {
        for (final s in species!) {
          legend.add((s.ink, s.label));
        }
      } else {
        for (final t in typesSeen) {
          legend.add((markFor(t).argb, '${_cap(t)} record'));
        }
      }
      if (removalSeen.contains('flagged')) {
        legend.add((removalRed, 'Flagged for removal'));
      }
      if (removalSeen.contains('removed')) {
        legend.add((PlateInk.ink, 'Removed'));
      }
      if (overlapGroups > 0) {
        legend.add((PlateInk.ink, 'Several records at one spot'));
      }
    }

    // Zone labels on top of everything but the furniture.
    if (layers.zones && layers.zoneLabels) {
      for (final z in subject.zones) {
        final c = _centroid(z.geojson);
        if (c == null) continue;
        final (x, y) = frame.toPlate(c.$1, c.$2);
        _drawLabel(canvas, z.name, x, y, size: 13, halo: true, center: true);
      }
    }

    // The image is the map and nothing else (title, legend, and notes live
    // in the document around it): scale bar, north, attribution only.
    _drawMapFurniture(
      canvas,
      frame,
      attribution: attribution,
      missing: missing,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (frame.width * scale).round(),
      (frame.height * scale).round(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return PlateResult(
      png: bytes!.buffer.asUint8List(),
      width: (frame.width * scale).round(),
      height: (frame.height * scale).round(),
      zoom: zoom,
      bounds: bounds,
      tilesMissing: missing,
      legend: legend,
      overlapGroups: overlapGroups,
      numbered: numbered,
    );
  }

  /// The colour a zone draws in, resolved exactly as [render] resolves it —
  /// so the document's zone table can carry the same swatch.
  static int zoneInk(PlateZone z, int index) =>
      _parseHex(z.colorHex) ??
      PlateInk.zoneFills[index % PlateInk.zoneFills.length];

  /// The box the plate frames: boundary if drawn, else every drawn layer's
  /// geometry, padded. Pure, so the framing is testable without rendering.
  static LatLngBounds frameBounds(PlateSubject s, PlateLayers layers) {
    final pts = <(double, double)>[];
    void addGeo(String? geojson) {
      final g = _decode(geojson);
      if (g == null) return;
      _walkCoords(g, (lat, lng) => pts.add((lat, lng)));
    }

    if (layers.boundary) addGeo(s.boundaryGeojson);
    if (pts.isEmpty || !layers.boundary) {
      if (layers.zones) {
        for (final z in s.zones) {
          addGeo(z.geojson);
        }
      }
      if (layers.features) {
        for (final f in s.features) {
          addGeo(f.geojson);
        }
      }
      if (layers.records) {
        for (final r in s.records) {
          pts.add((r.lat, r.lng));
        }
      }
      if (layers.tracks) {
        for (final t in s.tracks) {
          addGeo(t.geojson);
        }
      }
    }
    if (pts.isEmpty) {
      // Nothing drawable: still frame something so the caller sees paper.
      addGeo(s.boundaryGeojson);
      for (final z in s.zones) {
        addGeo(z.geojson);
      }
      for (final r in s.records) {
        pts.add((r.lat, r.lng));
      }
    }
    final b =
        LatLngBounds.ofPoints(pts) ??
        const LatLngBounds(south: 30.9, west: -98.2, north: 31.2, east: -97.9);
    var bb = b.pad(0.08);
    // A near-collinear subject — five records down one street — frames as
    // a ribbon and the page gets a sliver of map (Austin, 2026-09-03).
    // Open the short axis until the window is page-shaped.
    final latMid = (bb.north + bb.south) / 2;
    final mPerLng = 111320 * math.cos(latMid * math.pi / 180);
    final wM = (bb.east - bb.west) * mPerLng;
    final hM = (bb.north - bb.south) * 110574;
    if (hM < wM * 0.6) {
      final grow = (wM * 0.6 - hM) / 110574 / 2;
      bb = LatLngBounds(
        south: bb.south - grow,
        west: bb.west,
        north: bb.north + grow,
        east: bb.east,
      );
    } else if (wM < hM * 0.7) {
      final grow = (hM * 0.7 - wM) / mPerLng / 2;
      bb = LatLngBounds(
        south: bb.south,
        west: bb.west - grow,
        north: bb.north,
        east: bb.east + grow,
      );
    }
    return bb;
  }

  /// Records within [radiusPx] of each other collapse into one group. Greedy
  /// and order-dependent, which is fine at plate scale.
  static List<((double, double), List<PlateRecord>)> groupOverlapping(
    PlateFrame frame,
    List<PlateRecord> records, {
    double radiusPx = 9,
  }) {
    final groups = <((double, double), List<PlateRecord>)>[];
    for (final r in records) {
      final (x, y) = frame.toPlate(r.lat, r.lng);
      var placed = false;
      for (var i = 0; i < groups.length; i++) {
        final (gx, gy) = groups[i].$1;
        if ((gx - x).abs() <= radiusPx && (gy - y).abs() <= radiusPx) {
          groups[i].$2.add(r);
          placed = true;
          break;
        }
      }
      if (!placed) groups.add(((x, y), [r]));
    }
    return groups;
  }
}
