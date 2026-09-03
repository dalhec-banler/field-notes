import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../db/database.dart';
import 'map_plate.dart';

/// Assemble the plate's subject from the property's live rows. Soft-deleted
/// rows are excluded everywhere; a record's label is the species when it
/// has one (common name first), else nothing.
Future<PlateSubject> loadPlateSubject(
  FieldNotesDb db,
  Property property,
) async {
  final zones =
      await (db.select(db.zones)
            ..where((z) => z.propertyId.equals(property.id))
            ..where((z) => z.deletedAt.isNull())
            ..orderBy([(z) => OrderingTerm.asc(z.name)]))
          .get();
  final types = {
    for (final t in await db.select(db.featureTypes).get()) t.id: t,
  };
  final features =
      await (db.select(db.features)
            ..where((f) => f.propertyId.equals(property.id))
            ..where((f) => f.deletedAt.isNull()))
          .get();
  final taxa = {
    for (final t in await db.select(db.taxa).get())
      t.id: t.commonName ?? t.scientificName,
  };
  final observations =
      await (db.select(db.observations)
            ..where((o) => o.propertyId.equals(property.id))
            ..where((o) => o.deletedAt.isNull()))
          .get();
  final tracks =
      await (db.select(db.tracks)
            ..where((t) => t.propertyId.equals(property.id))
            ..where((t) => t.deletedAt.isNull())
            ..where((t) => t.geojson.isNotNull()))
          .get();

  return PlateSubject(
    propertyName: property.name,
    boundaryGeojson: property.boundaryGeojson,
    zones: [
      for (final z in zones)
        PlateZone(
          name: z.name,
          geojson: z.geojson,
          colorHex: z.colorHex,
          areaAcres: z.areaAcres ?? acresOf(z.geojson),
        ),
    ],
    features: [
      for (final f in features)
        PlateFeature(
          name: f.name ?? types[f.featureTypeId]?.label ?? 'Feature',
          featureClass: types[f.featureTypeId]?.featureClass ?? 'natural',
          geojson: f.geojson,
        ),
    ],
    records: [
      for (final o in observations)
        PlateRecord(
          id: o.id,
          lat: o.lat,
          lng: o.lng,
          type: o.observationType,
          label: o.taxonId == null ? null : taxa[o.taxonId],
        ),
    ],
    tracks: [
      for (final t in tracks) PlateTrack(geojson: t.geojson!, label: t.purpose),
    ],
  );
}

/// Acres from a Polygon/MultiPolygon GeoJSON string, or null if it can't
/// be read. Used when a zone arrived without `area_acres` (KML import).
/// Spherical excess per ring (Chamberlain & Duquette, the same formula
/// turf uses); holes subtract.
double? acresOf(String geojson) {
  try {
    final g = jsonDecode(geojson) as Map<String, dynamic>;
    double polygon(List rings) {
      var a = 0.0;
      for (var i = 0; i < rings.length; i++) {
        final r = _ringAreaM2(rings[i] as List);
        a += i == 0 ? r : -r;
      }
      return a;
    }

    final m2 = switch (g['type']) {
      'Polygon' => polygon(g['coordinates'] as List),
      'MultiPolygon' => [
        for (final p in g['coordinates'] as List) polygon(p as List),
      ].fold(0.0, (a, b) => a + b),
      _ => double.nan,
    };
    if (m2.isNaN || m2 <= 0) return null;
    return m2 / 4046.8564224;
  } catch (_) {
    return null;
  }
}

/// Acres of one ring given as `[lng, lat]` pairs (open or closed) — the
/// polygon editor's live readout, skipping the GeoJSON round trip.
double? acresOfRing(List<List<double>> ring) {
  final m2 = _ringAreaM2(ring);
  if (m2.isNaN || m2 <= 0) return null;
  return m2 / 4046.8564224;
}

double _ringAreaM2(List ring) {
  const radius = 6378137.0;
  final n = ring.length;
  if (n < 3) return 0;
  var total = 0.0;
  for (var i = 0; i < n; i++) {
    final p1 = ring[i] as List;
    final p2 = ring[(i + 1) % n] as List;
    final p3 = ring[(i + 2) % n] as List;
    final lon1 = (p1[0] as num).toDouble() * math.pi / 180;
    final lat2 = (p2[1] as num).toDouble() * math.pi / 180;
    final lon3 = (p3[0] as num).toDouble() * math.pi / 180;
    total += (lon3 - lon1) * math.sin(lat2);
  }
  return (total * radius * radius / 2).abs();
}
