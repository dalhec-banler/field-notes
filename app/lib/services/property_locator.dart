import 'package:drift/drift.dart';
import 'package:geolocator/geolocator.dart';

import '../db/database.dart';
import '../geo/state_resolver.dart';
import '../species/region_library.dart';

/// Where a place is, learned rather than asked.
///
/// Creating a place asks for a name and nothing else (D-003: a phone in a
/// pasture). The location arrives later, from whichever comes first — a
/// boundary drawn or imported, or the first located record — and this
/// service turns that first coordinate into the two things the app needs
/// to know about a place: a centroid to open the map on, and the state,
/// which picks the species library and the state-agency wording.
///
/// Nothing here blocks a save and nothing here touches the network.
class PropertyLocator {
  PropertyLocator(this.db);

  final FieldNotesDb db;

  /// A coordinate on the property became known. Sets the centroid when the
  /// place has none, and the state when the place has none. Returns the
  /// state resolved (new or already known), or null when the point is
  /// outside every US state.
  Future<UsState?> noteLocation(
    String propertyId,
    double lat,
    double lng, {
    bool setCentroid = true,
  }) async {
    final property = await (db.select(
      db.properties,
    )..where((p) => p.id.equals(propertyId))).getSingleOrNull();
    if (property == null) return null;

    final resolver = await StateResolver.load();
    final state = resolver.stateAt(lat, lng);
    final known = property.state == null
        ? null
        : resolver.byUsps(property.state!);

    final needsCentroid =
        setCentroid &&
        (property.centroidLat == null || property.centroidLng == null);
    final needsState = property.state == null && state != null;
    if (!needsCentroid && !needsState) return known ?? state;

    await (db.update(
      db.properties,
    )..where((p) => p.id.equals(propertyId))).write(
      PropertiesCompanion(
        centroidLat: needsCentroid ? Value(lat) : const Value.absent(),
        centroidLng: needsCentroid ? Value(lng) : const Value.absent(),
        state: needsState ? Value(state.usps) : const Value.absent(),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    if (needsState) {
      // The state's bundled palette lands the moment the state is known —
      // offline, from the app's own assets (D-034).
      try {
        await RegionLibrary(db).seedBundledPalette(state.usps);
      } catch (_) {}
    }
    return known ?? state;
  }

  /// The user chose a state from a list — a place they have not stood on
  /// yet, or a point the resolver could not place. Always writes.
  Future<void> setState(String propertyId, String usps) async {
    await (db.update(
      db.properties,
    )..where((p) => p.id.equals(propertyId))).write(
      PropertiesCompanion(
        state: Value(usps.toUpperCase()),
        updatedAt: Value(nowUtcIso()),
      ),
    );
  }

  /// Best-effort, never waits: the phone's last known fix, if the OS has one
  /// cached and permission is already granted. Used right after ADD A PLACE
  /// so a place created while standing on it is located from the start.
  Future<UsState?> noteLastKnownFix(String propertyId) async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) return null;
      return await noteLocation(propertyId, last.latitude, last.longitude);
    } catch (_) {
      return null;
    }
  }
}
