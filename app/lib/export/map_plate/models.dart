part of '../map_plate.dart';

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
  final net = FieldNetwork.forClient(client);
  final t = template ?? usgsImageryTemplate;
  return (z, x, y) async {
    final url = t
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y');
    try {
      final res = await net
          .get(
            Uri.parse(url),
            EgressPurpose.plate,
            headers: {'User-Agent': 'FieldNotes/1.1'},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      return res.bodyBytes;
    } catch (e, st) {
      Diag.report(e, st, where: 'map_plate.httpTileFetcher');
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
    this.removal,
    this.nativity,
    this.notes,
    this.photoPath,
  });
  final double lat, lng;
  final String type; // observation_type
  final String? label; // species, when identified

  /// D-027: 'flagged' or 'removed', when this record is removal work.
  final String? removal;

  /// The species' nativity and the record's notes and first photo — what
  /// a removal plan lists beside each numbered pin. The plate renderer
  /// itself never reads them.
  final String? nativity;
  final String? notes;
  final String? photoPath;

  /// Observation id and time — the desk map opens the record from its
  /// mark and lists sightings per species. The plate renderer itself
  /// never reads either.
  final String? id;
  final String? observedAt;
}

/// One species chosen for a species-coloured plate (Austin, 2026-09-03:
/// "a way for X amt of species to be depicted... different colors for
/// each species"). key matches records' label (or `__type:<type>` for
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
    this.numbered = const [],
  });
  final Uint8List png;

  /// Removal plan: the flagged records in the order their pins are
  /// numbered — the list beside the map says the same numbers.
  final List<PlateRecord> numbered;
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
