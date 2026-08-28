import 'dart:convert';
import 'dart:math' as math;

import 'package:turf/turf.dart' as turf;

import '../db/database.dart';
import 'simplify.dart' show distanceM;

/// Are you standing on the place you're looking at?
///
/// The app behaves differently on site and off it: on site the map follows
/// you and a capture is a record of where you are; off site the map belongs
/// to the property and the chrome says plainly that you're somewhere else.
/// Getting this wrong is worse than useless — a phone in town shouldn't drag
/// the map 90 miles from the land it's meant to show.
class SitePresence {
  const SitePresence({
    required this.onSite,
    required this.distanceM,
    required this.hasBoundary,
  });

  /// Inside the boundary, or within [nearRadiusM] of the centroid when the
  /// property has no boundary yet.
  final bool onSite;

  /// Metres from the property centroid, or null when the property has no
  /// location at all (no boundary, no centroid) or there is no fix.
  final double? distanceM;

  final bool hasBoundary;

  /// Unknown position or placeless property: don't claim either way.
  static const unknown =
      SitePresence(onSite: false, distanceM: null, hasBoundary: false);

  /// A property with no boundary is "here" within this radius of its
  /// centroid — a generous stand-in for a fence line we don't have.
  static const nearRadiusM = 1500.0;

  /// Human phrasing for the chrome: "1.2 km away", "92 km away".
  String get awayLabel {
    final d = distanceM;
    if (d == null) return 'away';
    if (d < 1000) return '${d.round()} m away';
    if (d < 100000) return '${(d / 1000).toStringAsFixed(1)} km away';
    return '${(d / 1000).round()} km away';
  }
}

/// Where the property sits: its boundary's centre if it has one, else the
/// stored centroid. Null when the property has no location yet.
List<double>? propertyCentre(Property property) {
  if (property.centroidLat != null && property.centroidLng != null) {
    return [property.centroidLng!, property.centroidLat!];
  }
  final bounds = propertyBounds(property);
  if (bounds == null) return null;
  return [(bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2];
}

/// `[minLon, minLat, maxLon, maxLat]` of the boundary, or null.
List<double>? propertyBounds(Property property) {
  final raw = property.boundaryGeojson;
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw);
    final coords = <List<double>>[];
    void walk(Object? node) {
      if (node is List) {
        if (node.length >= 2 && node[0] is num && node[1] is num) {
          coords.add([(node[0] as num).toDouble(), (node[1] as num).toDouble()]);
        } else {
          for (final child in node) {
            walk(child);
          }
        }
      } else if (node is Map) {
        walk(node['coordinates'] ?? node['geometry']);
      }
    }

    walk(decoded);
    if (coords.isEmpty) return null;
    var minLon = coords.first[0], maxLon = coords.first[0];
    var minLat = coords.first[1], maxLat = coords.first[1];
    for (final c in coords) {
      minLon = math.min(minLon, c[0]);
      maxLon = math.max(maxLon, c[0]);
      minLat = math.min(minLat, c[1]);
      maxLat = math.max(maxLat, c[1]);
    }
    return [minLon, minLat, maxLon, maxLat];
  } catch (_) {
    return null;
  }
}

/// Decide whether [lat]/[lng] is on [property].
SitePresence presenceFor(Property property, double? lat, double? lng) {
  if (lat == null || lng == null) return SitePresence.unknown;
  final centre = propertyCentre(property);
  final boundary = property.boundaryGeojson;
  final distance =
      centre == null ? null : distanceM([lng, lat], centre);

  if (boundary != null) {
    try {
      final geometry = turf.GeometryObject.deserialize(
          jsonDecode(boundary) as Map<String, dynamic>);
      final feature = turf.Feature(geometry: _asPolygon(geometry));
      final inside =
          turf.booleanPointInPolygon(turf.Position(lng, lat), feature);
      // Just outside a fence line is still "here" — GPS is ±5 m and people
      // walk the road side of a boundary.
      final near = distance != null && distance <= 250;
      return SitePresence(
          onSite: inside || near, distanceM: distance, hasBoundary: true);
    } catch (_) {
      // Unparseable boundary: fall through to the radius test.
    }
  }
  if (distance == null) return SitePresence.unknown;
  return SitePresence(
    onSite: distance <= SitePresence.nearRadiusM,
    distanceM: distance,
    hasBoundary: false,
  );
}

turf.GeometryType _asPolygon(turf.GeometryObject g) {
  if (g is turf.Polygon) return g;
  if (g is turf.MultiPolygon) {
    return turf.Polygon(coordinates: g.coordinates.first);
  }
  throw const FormatException('boundary is not a polygon');
}
