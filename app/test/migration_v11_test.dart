import 'dart:io';

import 'package:drift/drift.dart';
import 'package:field_notes/db/database.dart';
import 'package:flutter_test/flutter_test.dart';

/// v11 gives zones an import_id and adds the map_imports register, so a whole
/// imported map can be taken back out again. Zones drawn by hand carry a null
/// import_id and must survive that untouched.
void main() {
  test('v11 adds the import register and leaves hand-drawn zones alone', () async {
    final dir = await Directory.systemTemp.createTemp('fn_v11');
    final file = File('${dir.path}/db.sqlite');
    final db = FieldNotesDb.fromFile(file);
    final now = nowUtcIso();

    final prop = newId();
    await db.into(db.properties).insert(PropertiesCompanion.insert(
          id: prop, name: 'Test place', createdBy: 'local',
          createdAt: now, updatedAt: now,
        ));
    final drawn = newId();
    await db.into(db.zones).insert(ZonesCompanion.insert(
          id: drawn, propertyId: prop, name: 'Drawn by hand',
          geojson: '{"type":"Polygon","coordinates":[[[0,0],[0,1],[1,1],[0,0]]]}',
          createdBy: 'local', createdAt: now, updatedAt: now,
        ));

    final imp = newId();
    await db.into(db.mapImports).insert(MapImportsCompanion.insert(
          id: imp, propertyId: prop, sourceName: 'shorts.kml',
          sourceKind: 'file', importedAt: now,
          createdBy: 'local', createdAt: now, updatedAt: now,
        ));
    final fromFile = newId();
    await db.into(db.zones).insert(ZonesCompanion.insert(
          id: fromFile, propertyId: prop, name: 'Came from the file',
          geojson: '{"type":"Polygon","coordinates":[[[0,0],[0,2],[2,2],[0,0]]]}',
          importId: Value(imp),
          createdBy: 'local', createdAt: now, updatedAt: now,
        ));

    // removing the import takes its zones and spares the hand-drawn one
    final ids = (await (db.select(db.zones)
              ..where((z) => z.importId.equals(imp)))
            .get())
        .map((z) => z.id)
        .toList();
    expect(ids, [fromFile]);
    await (db.update(db.zones)..where((z) => z.id.isIn(ids)))
        .write(ZonesCompanion(deletedAt: Value(now), updatedAt: Value(now)));

    final live = await (db.select(db.zones)..where((z) => z.deletedAt.isNull())).get();
    expect(live.map((z) => z.id), [drawn]);
    expect(live.single.importId, null);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data['user_version'], db.schemaVersion);
    await db.close();
    await dir.delete(recursive: true);
  });
}
