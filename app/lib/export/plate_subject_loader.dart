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
  // Hidden zones don't paint — not on the desk map, not on a plate, not in
  // an export. They still exist and still own their records.
  final zones = await db.zonesToDraw(property.id);
  final types = {
    for (final t in await db.select(db.featureTypes).get()) t.id: t,
  };
  final features =
      await (db.select(db.features)
            ..where((f) => f.propertyId.equals(property.id))
            ..where((f) => f.deletedAt.isNull()))
          .get();
  final taxa = {for (final t in await db.select(db.taxa).get()) t.id: t};
  final observations =
      await (db.select(db.observations)
            ..where((o) => o.propertyId.equals(property.id))
            ..where((o) => o.deletedAt.isNull())
            // A record saved without a fix carries gps_accuracy_m = -1 and
            // placeholder coordinates. It must not be drawn as though it
            // were surveyed — it used to land at (0, 0) or at a fabricated
            // centroid, and it stretched the desk map's framing across the
            // ocean (external audit 2026-09-04, finding 14). The full
            // GeoJSON export always honoured the flag; now the plate,
            // the desk map and the HTML agree with it.
            ..where(
              (o) => o.gpsAccuracyM.equals(-1).not() | o.gpsAccuracyM.isNull(),
            ))
          .get();
  // Each record's first photo (thumbnail when there is one) — the removal
  // plan prints it beside the pin. Media stays on this machine; only the
  // plan the person saves carries it.
  final photoByObs = <String, String>{};
  if (observations.isNotEmpty) {
    final links =
        await (db.select(db.mediaLinks)
              ..where((l) => l.entityType.equals('observation'))
              ..where((l) => l.deletedAt.isNull())
              ..where(
                (l) => l.entityId.isIn([for (final o in observations) o.id]),
              ))
            .get();
    if (links.isNotEmpty) {
      final media = {
        for (final m
            in await (db.select(db.media)
                  ..where((m) => m.id.isIn([for (final l in links) l.mediaId]))
                  ..where((m) => m.mediaType.equals('photo'))
                  ..where((m) => m.deletedAt.isNull()))
                .get())
          m.id: m,
      };
      for (final l in links) {
        final m = media[l.mediaId];
        final path = m?.thumbPath ?? m?.localPath;
        if (path == null) continue;
        // Primary first; otherwise whichever link came first.
        if (l.role == 'primary' || !photoByObs.containsKey(l.entityId)) {
          photoByObs[l.entityId] = path;
        }
      }
    }
  }
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
          id: f.id,
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
          label: o.taxonId == null
              ? null
              : taxa[o.taxonId]?.commonName ?? taxa[o.taxonId]?.scientificName,
          observedAt: o.observedAt,
          removal: o.removalStatus,
          nativity: o.taxonId == null ? null : taxa[o.taxonId]?.nativity,
          notes: o.notes,
          photoPath: photoByObs[o.id],
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
