import '../db/database.dart';
import '../map/layers/layer_loader.dart';
import 'map_plate.dart';

// Acreage used to live here; it is geometry, not export, and the polygon
// editor reads it too. Kept reachable from the old address.
export '../geo/acres.dart' show acresOf, acresOfRing;

/// The plate's subject is the one layer set (D-038 item 11), read with
/// each record's first photo because the removal plan prints it beside
/// the pin. What this returns is exactly what the old per-table loader
/// returned — `test/map_layers_test.dart` holds it to the snapshot.
Future<PlateSubject> loadPlateSubject(
  FieldNotesDb db,
  Property property,
) async => PlateSubject.of(
  await MapLayerLoader(db).load(property, withPhotos: true),
);
