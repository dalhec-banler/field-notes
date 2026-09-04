import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import '../map/record_ink.dart';
import 'web_mercator.dart';

/// A map plate (D-024): the property's geometry composited over public
/// imagery into one raster the desk can preview, print, or hand to a
/// grantor. Our own renderer — maplibre_gl has no desktop platform — and
/// deliberately simple: tiles, polygons, points, lines, furniture.
///
/// Nothing here reads the database; the caller assembles a [PlateSubject]
/// so the renderer is host-testable with fabricated geometry and a fake
/// tile fetcher.

/// Returns PNG/JPEG bytes for a tile, or null when the service has none
/// (the plate paints paper there rather than failing).
typedef TileFetcher = Future<Uint8List?> Function(int z, int x, int y);

/// USGS National Map imagery — public domain, no key. The same source the
/// phone's satellite layer draws.
const usgsImageryTemplate =
    'https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}';

/// Topographic bases for the plate (the Plateau-style property map,
/// 2026-09-04): USGS's own topo, and the aerial+topo blend. Public
/// domain, no key. These are PLATE bases, not app map sources.
const usgsTopoTemplate =
    'https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}';
const usgsImageryTopoTemplate =
    'https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}';

/// One-shot overlay services drawn over the base at the frame's bbox:
/// hydrology and contours from The National Map, soil map units from
/// USDA-NRCS. All public domain; each request sends only the framed bbox.
const _hydroExport =
    'https://hydro.nationalmap.gov/arcgis/rest/services/nhd/MapServer/export';
const _contoursExport =
    'https://carto.nationalmap.gov/arcgis/rest/services/contours/MapServer/export';
const _soilsWms = 'https://SDMDataAccess.sc.egov.usda.gov/Spatial/SDM.wms';

TileFetcher httpTileFetcher({http.Client? client, String? template}) {
  final c = client ?? http.Client();
  final t = template ?? usgsImageryTemplate;
  return (z, x, y) async {
    final url = t
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y');
    try {
      final res = await c
          .get(Uri.parse(url), headers: {'User-Agent': 'FieldNotes/1.1'})
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  };
}

class PlateZone {
  const PlateZone({
    required this.name,
    required this.geojson,
    this.colorHex,
    this.areaAcres,
  });
  final String name;
  final String geojson; // Polygon / MultiPolygon
  final String? colorHex;
  final double? areaAcres;
}

class PlateFeature {
  const PlateFeature({
    required this.name,
    required this.featureClass, // natural | infrastructure | problem
    required this.geojson,
    this.id,
  });
  final String name;
  final String featureClass;
  final String geojson; // Point / LineString / Polygon

  /// Feature id — the desk map opens it from its mark; the renderer
  /// never reads it.
  final String? id;
}

class PlateRecord {
  const PlateRecord({
    required this.lat,
    required this.lng,
    required this.type,
    this.label,
    this.id,
    this.observedAt,
  });
  final double lat, lng;
  final String type; // observation_type
  final String? label; // species, when identified

  /// Observation id and time — the desk map opens the record from its
  /// mark and lists sightings per species. The plate renderer itself
  /// never reads either.
  final String? id;
  final String? observedAt;
}

/// One species chosen for a species-coloured plate (Austin, 2026-09-03:
/// "a way for X amt of species to be depicted... different colors for
/// each species"). key matches records' label (or '__type:<type>' for
/// unnamed records); ink is the colour it wears on this plate.
class PlateSpecies {
  const PlateSpecies(this.key, this.label, this.ink);
  final String key;
  final String label;
  final int ink;
}

class PlateTrack {
  const PlateTrack({required this.geojson, this.label});
  final String geojson; // LineString
  final String? label;
}

class PlateSubject {
  const PlateSubject({
    required this.propertyName,
    this.boundaryGeojson,
    this.zones = const [],
    this.features = const [],
    this.records = const [],
    this.tracks = const [],
  });
  final String propertyName;
  final String? boundaryGeojson;
  final List<PlateZone> zones;
  final List<PlateFeature> features;
  final List<PlateRecord> records;
  final List<PlateTrack> tracks;
}

/// Which layers the plate carries. Records carry coordinates of private
/// land (hard rule 3); the caller surfaces that at the point of export.
class PlateLayers {
  const PlateLayers({
    this.boundary = true,
    this.zones = true,
    this.zoneLabels = true,
    this.features = true,
    this.records = false,
    this.tracks = false,
    this.hydro = false,
    this.contours = false,
    this.soils = false,
  });
  final bool boundary, zones, zoneLabels, features, records, tracks;

  /// Government overlays (the Plateau map's optional layers): hydrology,
  /// elevation contours, soil map units.
  final bool hydro;
  final bool contours;
  final bool soils;

  PlateLayers copyWith({
    bool? boundary,
    bool? zones,
    bool? zoneLabels,
    bool? features,
    bool? records,
    bool? tracks,
    bool? hydro,
    bool? contours,
    bool? soils,
  }) => PlateLayers(
    boundary: boundary ?? this.boundary,
    zones: zones ?? this.zones,
    zoneLabels: zoneLabels ?? this.zoneLabels,
    features: features ?? this.features,
    records: records ?? this.records,
    tracks: tracks ?? this.tracks,
    hydro: hydro ?? this.hydro,
    contours: contours ?? this.contours,
    soils: soils ?? this.soils,
  );
}

class PlateResult {
  const PlateResult({
    required this.png,
    required this.width,
    required this.height,
    required this.zoom,
    required this.bounds,
    required this.tilesMissing,
    required this.legend,
    required this.overlapGroups,
  });
  final Uint8List png;
  final int width, height, zoom;
  final LatLngBounds bounds;

  /// Tiles the imagery service had nothing for — printed on the plate.
  final int tilesMissing;

  /// (swatch colour ARGB, label) pairs in draw order.
  final List<(int, String)> legend;

  /// Records that shared a pixel and were drawn as one badge with a count.
  final int overlapGroups;
}

/// Palette — the plate has its own ink so it prints the same from either
/// skin. Values mirror the press tokens.
abstract final class PlateInk {
  static const paper = 0xFFF7F6F2;
  static const ink = 0xFF1B1813;
  static const oxblood = 0xFF8B2E22;
  static const sage = 0xFF4E6B4A;
  static const ochre = 0xFFA8791F;
  static const river = 0xFF2F5D8A;
  static const zoneFills = [
    0xFF4E6B4A,
    0xFF7A8C3B,
    0xFFA8791F,
    0xFF2F5D8A,
    0xFF8B2E22,
    0xFF5D5A8A,
    0xFF3F7A73,
    0xFFB5652B,
    0xFF6B7F2E,
    0xFF7E4E7A,
  ];

  /// Distinct hues for species-coloured plates — picked apart from the
  /// boundary oxblood and legible on imagery under a white halo.
  static const speciesWheel = [
    0xFF2F5D8A, // river
    0xFFB5652B, // rust
    0xFF7A8C3B, // moss
    0xFF7E4E7A, // plum
    0xFF3F7A73, // teal
    0xFFC9564B, // coral
    0xFF5D5A8A, // violet
    0xFF6B7F2E, // olive
    0xFF9B3D63, // magenta
    0xFF8E6A28, // bronze
    0xFF2E7D52, // pine
    0xFF8A6FA8, // lavender
  ];

  static const recordTypes = {
    'plant': 0xFF4E6B4A,
    'wildlife': 0xFFA8791F,
    'problem': 0xFF8B2E22,
    'water': 0xFF2F5D8A,
    'soil': 0xFF7A5C3B,
    'phenology': 0xFF7A8C3B,
    'sign': 0xFFA8791F,
    'weather': 0xFF5D5A8A,
    'maintenance': 0xFF1B1813,
    'infrastructure': 0xFF1B1813,
    'general': 0xFF6B655C,
  };
}

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
    if (layers.records && subject.records.isNotEmpty) {
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

  /// EPSG:3857 bbox string for the frame's bounds.
  static String _mercBboxOf(LatLngBounds b) {
    const r = 6378137.0;
    double mx(double lon) => lon * math.pi / 180 * r;
    double my(double lat) =>
        r * math.log(math.tan(math.pi / 4 + lat * math.pi / 360));
    return '${mx(b.west)},${my(b.south)},${mx(b.east)},${my(b.north)}';
  }

  /// One overlay image; the government endpoints hiccup (a 502 answered
  /// this exact request during development), so try three times and let
  /// a miss mean a missing layer, never a failed plate.
  Future<ui.Image?> _fetchOverlayImage(String url) async {
    final client = http.Client();
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final res = await client
              .get(Uri.parse(url), headers: {'User-Agent': 'FieldNotes/1.1'})
              .timeout(const Duration(seconds: 25));
          final b = res.bodyBytes;
          final isImage =
              b.length > 8 && (b[0] == 0x89 || (b[0] == 0xFF && b[1] == 0xD8));
          if (res.statusCode == 200 && isImage) {
            final codec = await ui.instantiateImageCodec(b);
            final img = (await codec.getNextFrame()).image;
            codec.dispose();
            return img;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      return null;
    } finally {
      client.close();
    }
  }

  Future<Map<(int, int), (ui.Image, ui.Rect)?>> _fetchAll(
    PlateFrame frame, {
    int? srcMaxZoom,
  }) async {
    final srcMax = srcMaxZoom ?? frame.zoom;
    final depth = (frame.zoom - srcMax).clamp(0, 8);
    final out = <(int, int), (ui.Image, ui.Rect)?>{};
    final queue = frame.tiles.toList();
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final (tx, ty) = queue.removeLast();
        // Past the source's cache: fetch the parent and note which
        // quadrant this tile is (the tile cache dedups the network).
        final bytes = depth == 0
            ? await fetchTile(frame.zoom, tx, ty)
            : await fetchTile(srcMax, tx >> depth, ty >> depth);
        (ui.Image, ui.Rect)? entry;
        if (bytes != null) {
          try {
            final codec = await ui.instantiateImageCodec(bytes);
            final img = (await codec.getNextFrame()).image;
            codec.dispose();
            if (depth == 0) {
              entry = (
                img,
                ui.Rect.fromLTWH(
                  0,
                  0,
                  img.width.toDouble(),
                  img.height.toDouble(),
                ),
              );
            } else {
              final sub = 1 << depth;
              final q = img.width / sub;
              entry = (
                img,
                ui.Rect.fromLTWH(
                  (tx & (sub - 1)) * q,
                  (ty & (sub - 1)) * q,
                  q,
                  q,
                ),
              );
            }
          } catch (_) {
            entry = null;
          }
        }
        out[(tx, ty)] = entry;
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    return out;
  }

  // ── drawing helpers ────────────────────────────────────────────────

  static void _drawMissingTile(ui.Canvas c, double ox, double oy) {
    c.drawRect(
      ui.Rect.fromLTWH(ox, oy, tileSize, tileSize),
      ui.Paint()..color = const ui.Color(0xFFE8E6DF),
    );
    final p = ui.Paint()
      ..color = const ui.Color(0x22000000)
      ..strokeWidth = 1;
    for (var d = -tileSize; d < tileSize; d += 24) {
      c.drawLine(
        ui.Offset(ox + d, oy + tileSize),
        ui.Offset(ox + d + tileSize, oy),
        p,
      );
    }
  }

  /// The shared shape language (record_ink): circle for the grown and
  /// observed, square for the built, triangle for trouble — white halo,
  /// as everything prints.
  static void _drawRecordMark(
    ui.Canvas c,
    double x,
    double y,
    String type, {
    int? colorOverride,
  }) {
    final mark = markFor(type);
    final ink = colorOverride ?? mark.argb;
    switch (mark.shape) {
      case RecordShape.circle:
        _drawRecordDot(c, x, y, ink);
      case RecordShape.square:
        final rect = ui.Rect.fromCenter(
          center: ui.Offset(x, y),
          width: 10,
          height: 10,
        );
        c.drawRect(
          rect.inflate(2),
          ui.Paint()..color = const ui.Color(0xFFFFFFFF),
        );
        c.drawRect(rect, ui.Paint()..color = ui.Color(ink));
      case RecordShape.triangle:
        final tri = ui.Path()
          ..moveTo(x, y - 7)
          ..lineTo(x + 6, y + 4.5)
          ..lineTo(x - 6, y + 4.5)
          ..close();
        c.drawPath(
          tri,
          ui.Paint()
            ..color = const ui.Color(0xFFFFFFFF)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeJoin = ui.StrokeJoin.round,
        );
        c.drawPath(tri, ui.Paint()..color = ui.Color(ink));
    }
  }

  static void _drawRecordDot(ui.Canvas c, double x, double y, int color) {
    c.drawCircle(
      ui.Offset(x, y),
      6.5,
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    c.drawCircle(ui.Offset(x, y), 5, ui.Paint()..color = ui.Color(color));
  }

  static void _drawCountBadge(ui.Canvas c, double x, double y, int n) {
    final r = n >= 50
        ? 16.0
        : n >= 10
        ? 13.0
        : 11.0;
    c.drawCircle(
      ui.Offset(x, y),
      r + 1.5,
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    c.drawCircle(
      ui.Offset(x, y),
      r,
      ui.Paint()..color = ui.Color(PlateInk.ink),
    );
    _drawLabel(
      c,
      '$n',
      x,
      y,
      size: n >= 100 ? 10 : 12,
      color: PlateInk.paper,
      center: true,
      middle: true,
    );
  }

  static void _drawFeatureMarker(
    ui.Canvas c,
    double x,
    double y,
    String cls,
    int color,
  ) {
    final halo = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
    final fill = ui.Paint()..color = ui.Color(color);
    switch (cls) {
      case 'problem':
        final tri = ui.Path()
          ..moveTo(x, y - 9)
          ..lineTo(x + 8, y + 6)
          ..lineTo(x - 8, y + 6)
          ..close();
        c.drawPath(
          tri,
          halo
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 4,
        );
        c.drawPath(tri, fill);
      case 'infrastructure':
        final rect = ui.Rect.fromCenter(
          center: ui.Offset(x, y),
          width: 13,
          height: 13,
        );
        c.drawRect(rect.inflate(1.5), halo..style = ui.PaintingStyle.fill);
        c.drawRect(rect, fill);
      default:
        c.drawCircle(ui.Offset(x, y), 8, halo..style = ui.PaintingStyle.fill);
        c.drawCircle(ui.Offset(x, y), 6.5, fill);
        c.drawCircle(
          ui.Offset(x, y),
          2.5,
          ui.Paint()..color = const ui.Color(0xFFFFFFFF),
        );
    }
  }

  static ui.Paragraph _paragraph(
    String text,
    double size, {
    int color = PlateInk.ink,
    bool bold = false,
    ui.TextAlign align = ui.TextAlign.left,
    double maxWidth = 2000,
  }) {
    final b =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(textAlign: align, fontSize: size, maxLines: 2),
          )
          ..pushStyle(
            ui.TextStyle(
              color: ui.Color(color),
              fontSize: size,
              fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w500,
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: const ['Menlo', 'monospace'],
            ),
          )
          ..addText(text);
    return b.build()..layout(ui.ParagraphConstraints(width: maxWidth));
  }

  static void _drawLabel(
    ui.Canvas c,
    String text,
    double x,
    double y, {
    double size = 12,
    int color = PlateInk.ink,
    bool halo = false,
    bool center = false,
    bool middle = false,
    bool bold = false,
  }) {
    final p = _paragraph(text, size, color: color, bold: bold);
    final w = p.longestLine;
    final h = p.height;
    final dx = center ? x - w / 2 : x;
    final dy = middle ? y - h / 2 : y;
    if (halo) {
      c.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(dx - 5, dy - 2, w + 10, h + 4),
          const ui.Radius.circular(3),
        ),
        ui.Paint()..color = const ui.Color(0xD9F7F6F2),
      );
    }
    c.drawParagraph(p, ui.Offset(dx, dy));
  }

  static void _drawMapFurniture(
    ui.Canvas c,
    PlateFrame frame, {
    required String attribution,
    required int missing,
  }) {
    final w = frame.width.toDouble();
    final h = frame.height.toDouble();

    // Scale bar + north, bottom-left.
    final midLat = (frame.bounds.north + frame.bounds.south) / 2;
    final (metres, px) = scaleBar(midLat, frame.zoom);
    final label = metres >= 1000
        ? '${(metres / 1000).toStringAsFixed(metres % 1000 == 0 ? 0 : 1)} km'
        : '${metres.toStringAsFixed(0)} m';
    const sbx = 12.0;
    final sby = h - 12 - 34;
    c.drawRect(
      ui.Rect.fromLTWH(sbx, sby, px + 56, 34),
      ui.Paint()..color = const ui.Color(0xF2F7F6F2),
    );
    c.drawRect(
      ui.Rect.fromLTWH(sbx + 8, sby + 22, px, 4),
      ui.Paint()..color = ui.Color(PlateInk.ink),
    );
    c.drawRect(
      ui.Rect.fromLTWH(sbx + 8, sby + 22, px / 2, 4),
      ui.Paint()..color = ui.Color(PlateInk.paper),
    );
    c.drawRect(
      ui.Rect.fromLTWH(sbx + 8, sby + 22, px, 4),
      ui.Paint()
        ..color = ui.Color(PlateInk.ink)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    _drawLabel(c, label, sbx + 8, sby + 4, size: 10);
    final nx = sbx + px + 34;
    final arrow = ui.Path()
      ..moveTo(nx, sby + 6)
      ..lineTo(nx + 6, sby + 26)
      ..lineTo(nx, sby + 21)
      ..lineTo(nx - 6, sby + 26)
      ..close();
    c.drawPath(arrow, ui.Paint()..color = ui.Color(PlateInk.ink));
    _drawLabel(c, 'N', nx, sby - 8, size: 9, center: true, bold: true);

    // Attribution (+ missing tiles), bottom-right.
    final att = missing > 0
        ? '$attribution · $missing tile${missing == 1 ? '' : 's'} unavailable'
        : attribution;
    final ap = _paragraph(att, 9, color: 0xFF6B655C);
    c.drawRect(
      ui.Rect.fromLTWH(
        w - ap.longestLine - 24,
        h - ap.height - 18,
        ap.longestLine + 12,
        ap.height + 6,
      ),
      ui.Paint()..color = const ui.Color(0xD9F7F6F2),
    );
    c.drawParagraph(ap, ui.Offset(w - ap.longestLine - 18, h - ap.height - 15));
  }

  // ── geometry helpers ───────────────────────────────────────────────

  static Map<String, dynamic>? _decode(String? geojson) {
    if (geojson == null || geojson.isEmpty) return null;
    try {
      final v = jsonDecode(geojson);
      if (v is Map<String, dynamic>) {
        if (v['type'] == 'Feature') {
          return v['geometry'] as Map<String, dynamic>?;
        }
        return v;
      }
    } catch (_) {}
    return null;
  }

  static void _walkCoords(
    dynamic node,
    void Function(double lat, double lng) f,
  ) {
    if (node is Map) {
      final coords = node['coordinates'];
      if (coords != null) _walkCoords(coords, f);
      final geoms = node['geometries'];
      if (geoms is List) {
        for (final g in geoms) {
          _walkCoords(g, f);
        }
      }
      return;
    }
    if (node is List) {
      if (node.length >= 2 && node[0] is num && node[1] is num) {
        f((node[1] as num).toDouble(), (node[0] as num).toDouble());
      } else {
        for (final n in node) {
          _walkCoords(n, f);
        }
      }
    }
  }

  static ui.Path? _polygonPath(PlateFrame frame, String geojson) {
    final g = _decode(geojson);
    if (g == null) return null;
    final path = ui.Path();
    void ring(List r) {
      for (var i = 0; i < r.length; i++) {
        final c = r[i] as List;
        final (x, y) = frame.toPlate(
          (c[1] as num).toDouble(),
          (c[0] as num).toDouble(),
        );
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      path.close();
    }

    switch (g['type']) {
      case 'Polygon':
        for (final r in g['coordinates'] as List) {
          ring(r as List);
        }
      case 'MultiPolygon':
        for (final poly in g['coordinates'] as List) {
          for (final r in poly as List) {
            ring(r as List);
          }
        }
      default:
        return null;
    }
    path.fillType = ui.PathFillType.evenOdd;
    return path;
  }

  static ui.Path? _linePath(PlateFrame frame, String geojson) {
    final g = _decode(geojson);
    if (g == null) return null;
    final path = ui.Path();
    void line(List pts) {
      for (var i = 0; i < pts.length; i++) {
        final c = pts[i] as List;
        final (x, y) = frame.toPlate(
          (c[1] as num).toDouble(),
          (c[0] as num).toDouble(),
        );
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
    }

    switch (g['type']) {
      case 'LineString':
        line(g['coordinates'] as List);
      case 'MultiLineString':
        for (final l in g['coordinates'] as List) {
          line(l as List);
        }
      default:
        return null;
    }
    return path;
  }

  /// Average of the outer ring — good enough to place a label.
  static (double, double)? _centroid(String geojson) {
    final g = _decode(geojson);
    if (g == null) return null;
    List? ring;
    if (g['type'] == 'Polygon') {
      ring = (g['coordinates'] as List).first as List;
    } else if (g['type'] == 'MultiPolygon') {
      ring = ((g['coordinates'] as List).first as List).first as List;
    }
    if (ring == null || ring.isEmpty) return null;
    var sx = 0.0, sy = 0.0;
    for (final c in ring) {
      sx += ((c as List)[0] as num).toDouble();
      sy += (c[1] as num).toDouble();
    }
    return (sy / ring.length, sx / ring.length);
  }

  static int? _parseHex(String? hex) {
    if (hex == null) return null;
    var h = hex.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    return int.tryParse(h, radix: 16);
  }

  static String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
