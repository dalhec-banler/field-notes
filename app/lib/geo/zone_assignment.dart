import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:turf/turf.dart' as turf;

import '../db/database.dart';

/// Point-in-polygon zone auto-assignment (spec §4.5: observations get their
/// zone from where they land, not from user input).
///
/// With nested zones (§4.3 hierarchy) the deepest matching zone wins — a point
/// in "Section 3 > riparian corridor" belongs to the corridor.

/// A property's zones queried and parsed once, point lookups in memory.
/// The polygon-editor save re-derives every record on the property, and
/// re-querying + re-parsing every zone geometry per record was the cost.
class LoadedZones {
  LoadedZones._(this._features, this._parents);

  /// zone id → parsed (Multi)Polygon feature. Malformed geometry is simply
  /// absent — a bad zone never blocks a save.
  final Map<String, turf.Feature> _features;
  final Map<String, String?> _parents;

  static Future<LoadedZones> load(FieldNotesDb db, String propertyId) async {
    // Hidden zones still catch records — see FieldNotesDb.zonesOf.
    final zones = await db.zonesOf(propertyId);
    final features = <String, turf.Feature>{};
    for (final zone in zones) {
      try {
        final geometry = turf.GeometryObject.deserialize(
          jsonDecode(zone.geojson) as Map<String, dynamic>,
        );
        if (geometry is! turf.Polygon && geometry is! turf.MultiPolygon) {
          continue;
        }
        features[zone.id] = turf.Feature(
          geometry: geometry as turf.GeometryType,
        );
      } catch (_) {
        // Malformed zone geometry never blocks a save.
      }
    }
    return LoadedZones._(features, {
      for (final z in zones) z.id: z.parentZoneId,
    });
  }

  /// The id of the deepest zone containing (lat, lng), or null.
  String? zoneIdAt(double lat, double lng) {
    final point = turf.Position(lng, lat);
    final matches = <String>{};
    for (final e in _features.entries) {
      try {
        if (turf.booleanPointInPolygon(point, e.value)) matches.add(e.key);
      } catch (_) {}
    }
    if (matches.isEmpty) return null;
    if (matches.length == 1) return matches.first;

    // Deepest match: the zone with the most ancestors also in the match set.
    String best = matches.first;
    var bestDepth = -1;
    for (final id in matches) {
      var depth = 0;
      var parent = _parents[id];
      while (parent != null && matches.contains(parent)) {
        depth++;
        parent = _parents[parent];
      }
      if (depth > bestDepth) {
        bestDepth = depth;
        best = id;
      }
    }
    return best;
  }
}

/// One-shot lookup for a single point (capture flows).
class ZoneAssigner {
  ZoneAssigner(this.db);

  final FieldNotesDb db;

  /// Returns the id of the deepest zone containing (lat, lng), or null.
  Future<String?> zoneIdFor({
    required String propertyId,
    required double lat,
    required double lng,
  }) async => (await LoadedZones.load(db, propertyId)).zoneIdAt(lat, lng);
}

/// What chrome says where a record has no zone — one wording, honest about
/// the difference between "none drawn" and "landed outside them".
String noZoneLabel(int zoneCount) =>
    zoneCount == 0 ? 'no zones drawn yet' : 'outside every zone';

/// Convenience for capture flows: assigns and returns the zone id for a new
/// observation row already inserted with a null zone.
Future<String?> assignZone(
  FieldNotesDb db, {
  required String observationId,
  required String propertyId,
  required double lat,
  required double lng,
}) async {
  final zoneId = await ZoneAssigner(db)
      .zoneIdFor(propertyId: propertyId, lat: lat, lng: lng);
  if (zoneId != null) {
    await (db.update(
      db.observations,
    )..where((o) => o.id.equals(observationId))).write(
      ObservationsCompanion(
        zoneId: Value(zoneId),
        updatedAt: Value(nowUtcIso()),
      ),
    );
  }
  return zoneId;
}

/// Re-derive zone_id for every located record on the property — the zones
/// just moved (polygon editor), and the ledger must follow the new lines.
/// Zones are parsed once and the updates ride one transaction.
Future<int> reassignAllZones(FieldNotesDb db, String propertyId) async {
  final zones = await LoadedZones.load(db, propertyId);
  final rows =
      await (db.select(db.observations)
            ..where((o) => o.propertyId.equals(propertyId))
            ..where((o) => o.deletedAt.isNull())
            ..where(
              (o) => o.gpsAccuracyM.equals(-1).not() | o.gpsAccuracyM.isNull(),
            ))
          .get();
  var changed = 0;
  final now = nowUtcIso();
  await db.transaction(() async {
    for (final o in rows) {
      final zoneId = zones.zoneIdAt(o.lat, o.lng);
      if (zoneId == o.zoneId) continue;
      await (db.update(db.observations)..where((x) => x.id.equals(o.id))).write(
        ObservationsCompanion(zoneId: Value(zoneId), updatedAt: Value(now)),
      );
      changed++;
    }
  });
  return changed;
}
