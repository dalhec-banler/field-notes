import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:turf/turf.dart' as turf;

/// Which US state a point is in, resolved on the phone.
///
/// The property's centroid (or the first located record) tells the app what
/// state it is working in, and the state picks the species library and the
/// state-agency wording. Nothing is looked up online: the polygons are the
/// Census Bureau's 1:20m cartographic boundaries, bundled at ~100 m
/// precision, which is plenty for "which state" and useless for "where
/// exactly" — the file carries no private location.
class UsState {
  const UsState({required this.usps, required this.name, required this.fips});

  /// Two-letter postal code, e.g. 'TX'.
  final String usps;
  final String name;
  final String fips;

  @override
  String toString() => usps;
}

class StateResolver {
  StateResolver._(this._states);

  final List<(UsState, turf.Feature)> _states;

  static StateResolver? _cached;

  /// Loads the bundled polygons once; later calls are free.
  static Future<StateResolver> load({String? geojsonText}) async {
    final existing = _cached;
    if (existing != null && geojsonText == null) return existing;
    geojsonText ??= await rootBundle.loadString('assets/geo/us_states.geojson');
    final resolver = StateResolver.fromGeoJson(geojsonText);
    if (_cached == null) _cached = resolver;
    return resolver;
  }

  static StateResolver fromGeoJson(String text) {
    final fc = jsonDecode(text) as Map<String, dynamic>;
    final out = <(UsState, turf.Feature)>[];
    for (final f in (fc['features'] as List).cast<Map<String, dynamic>>()) {
      final props = f['properties'] as Map<String, dynamic>;
      final geometry = turf.GeometryObject.deserialize(
        f['geometry'] as Map<String, dynamic>,
      );
      if (geometry is! turf.Polygon && geometry is! turf.MultiPolygon) continue;
      out.add((
        UsState(
          usps: props['usps'] as String,
          name: props['name'] as String,
          fips: props['fips'] as String,
        ),
        turf.Feature(geometry: geometry as turf.GeometryType),
      ));
    }
    return StateResolver._(out);
  }

  /// The state containing (lat, lng), or null when the point is outside
  /// every state and territory in the file (open water, another country).
  UsState? stateAt(double lat, double lng) {
    final point = turf.Position(lng, lat);
    for (final (state, feature) in _states) {
      try {
        if (turf.booleanPointInPolygon(point, feature)) return state;
      } catch (_) {}
    }
    return null;
  }

  /// Look a state up by postal code — for a user who picks from a list.
  UsState? byUsps(String usps) {
    final code = usps.toUpperCase();
    for (final (state, _) in _states) {
      if (state.usps == code) return state;
    }
    return null;
  }

  /// Every state, alphabetically by name — the picker list.
  List<UsState> get all =>
      (_states.map((e) => e.$1).toList()
        ..sort((a, b) => a.name.compareTo(b.name)));
}
