import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:turf/turf.dart' as turf;

import '../db/database.dart';

/// Point-in-polygon zone auto-assignment (spec §4.5: observations get their
/// zone from where they land, not from user input).
///
/// With nested zones (§4.3 hierarchy) the deepest matching zone wins — a point
/// in "Section 3 > riparian corridor" belongs to the corridor.
class ZoneAssigner {
  ZoneAssigner(this.db);

  final FieldNotesDb db;

  /// Returns the id of the deepest zone containing (lat, lng), or null.
  Future<String?> zoneIdFor({
    required String propertyId,
    required double lat,
    required double lng,
  }) async {
    final zones = await (db.select(db.zones)
          ..where((z) => z.propertyId.equals(propertyId))
          ..where((z) => z.deletedAt.isNull()))
        .get();
    if (zones.isEmpty) return null;

    final point = turf.Position(lng, lat);
    final matches = <String>{};
    for (final zone in zones) {
      if (_contains(zone.geojson, point)) matches.add(zone.id);
    }
    if (matches.isEmpty) return null;
    if (matches.length == 1) return matches.first;

    // Deepest match: the zone with the most ancestors also in the match set.
    final byId = {for (final z in zones) z.id: z};
    String best = matches.first;
    var bestDepth = -1;
    for (final id in matches) {
      var depth = 0;
      var parent = byId[id]?.parentZoneId;
      while (parent != null && matches.contains(parent)) {
        depth++;
        parent = byId[parent]?.parentZoneId;
      }
      if (depth > bestDepth) {
        bestDepth = depth;
        best = id;
      }
    }
    return best;
  }

  bool _contains(String geojson, turf.Position point) {
    try {
      final geometry = turf.GeometryObject.deserialize(
        jsonDecode(geojson) as Map<String, dynamic>,
      );
      final feature = turf.Feature(geometry: _asPolygon(geometry));
      return turf.booleanPointInPolygon(point, feature);
    } catch (_) {
      return false; // malformed zone geometry never blocks a save
    }
  }

  turf.GeometryType _asPolygon(turf.GeometryObject g) {
    if (g is turf.Polygon || g is turf.MultiPolygon) {
      return g as turf.GeometryType;
    }
    throw const FormatException('zone geometry must be (Multi)Polygon');
  }
}

/// Convenience for capture flows: assigns and returns the zone id for a new
/// observation row already inserted with a null zone.
Future<String?> assignZone(
  FieldNotesDb db, {
  required String observationId,
  required String propertyId,
  required double lat,
  required double lng,
}) async {
  final zoneId = await ZoneAssigner(db).zoneIdFor(
    propertyId: propertyId,
    lat: lat,
    lng: lng,
  );
  if (zoneId != null) {
    await (db.update(db.observations)
          ..where((o) => o.id.equals(observationId)))
        .write(ObservationsCompanion(
      zoneId: Value(zoneId),
      updatedAt: Value(nowUtcIso()),
    ));
  }
  return zoneId;
}
