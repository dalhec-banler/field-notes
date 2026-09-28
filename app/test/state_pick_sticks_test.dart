import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/services/property_locator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Picking a state has to survive the moment you pick it.
///
/// The shell hands the library card a Property it read at boot and never
/// refreshes. The card read the state back off that snapshot, so the pick
/// landed in the database and the card immediately reset itself to asking
/// again — it only showed up after a relaunch, which is why it looked fine
/// on the desk, where the app gets restarted far more often (Austin,
/// 2026-09-28).
///
/// The card now follows the row instead. These cover the stream it follows:
/// a widget test can't, because the card loads its state polygons from the
/// asset bundle and that never resolves inside the tester's fake-async zone.
void main() {
  // The locator resolves the state from bundled Census polygons.
  TestWidgetsFlutterBinding.ensureInitialized();

  late FieldNotesDb db;
  setUp(() => db = FieldNotesDb.forTesting());
  tearDown(() => db.close());

  Future<Property> place({String? state}) async {
    final now = nowUtcIso();
    return db.into(db.properties).insertReturning(
          PropertiesCompanion.insert(
            id: newId(),
            name: 'Shorts Field Station',
            state: Value(state),
            createdBy: 'test',
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  Stream<String?> stateOf(String id) =>
      (db.select(db.properties)..where((p) => p.id.equals(id)))
          .watchSingleOrNull()
          .map((r) => r?.state);

  test('the picked state reaches a watcher that still holds the old row',
      () async {
    final p = await place();
    expect(p.state, isNull);

    final seen = <String?>[];
    final sub = stateOf(p.id).listen(seen.add);
    await pumpEventQueue();

    await PropertyLocator(db).setState(p.id, 'TX');
    await pumpEventQueue();
    await sub.cancel();

    expect(seen.first, isNull, reason: 'starts out not knowing');
    expect(seen.last, 'TX',
        reason: 'the write must reach a listener holding the stale Property');
  });

  test('the locator setting a state from a fix also reaches the watcher',
      () async {
    final p = await place();
    final seen = <String?>[];
    final sub = stateOf(p.id).listen(seen.add);
    await pumpEventQueue();

    // A point in Lampasas County, the other way a state gets set.
    await PropertyLocator(db).noteLocation(p.id, 31.0618, -98.1806);
    await pumpEventQueue();
    await sub.cancel();

    expect(seen.last, 'TX');
  });

  test('a state already on the row is what a fresh read returns', () async {
    final p = await place(state: 'TX');
    final row = await (db.select(db.properties)
          ..where((x) => x.id.equals(p.id)))
        .getSingle();
    expect(row.state, 'TX');
  });

  test('the locator never overwrites a state already chosen', () async {
    final p = await place(state: 'TX');
    // A fix in New Mexico must not silently re-home a place the user named.
    await PropertyLocator(db).noteLocation(p.id, 34.5, -106.0);
    final row = await (db.select(db.properties)
          ..where((x) => x.id.equals(p.id)))
        .getSingle();
    expect(row.state, 'TX');
  });
}
