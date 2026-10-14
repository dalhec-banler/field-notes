import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/repo/zones_repo.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

void main() {
  late FieldNotesDb db;
  late RepoFixture f;
  late ZonesRepo repo;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    f = await RepoFixture.seed(db);
    repo = ZonesRepo(db);
  });

  tearDown(() => db.close());

  test('byId', () async {
    expect((await repo.byId(f.northZoneId))?.name, 'North Pasture');
    expect(await repo.byId('nope'), isNull);
  });

  test('of keeps hidden zones; toDraw leaves them out (D-037)', () async {
    final hidden = await f.zone('Old Field', hidden: true);
    final gone = await f.zone('Gone');
    await (db.update(db.zones)..where((z) => z.id.equals(gone))).write(
      ZonesCompanion(deletedAt: Value(f.now)),
    );
    final all = await repo.of(f.propertyId, byName: true);
    expect(all.map((z) => z.name), ['Creek Corridor', 'North Pasture', 'Old Field']);
    expect(all.map((z) => z.id), contains(hidden));
    final drawn = await repo.toDraw(f.propertyId);
    expect(drawn.map((z) => z.name), ['Creek Corridor', 'North Pasture']);
  });

  test('changes fires on a zone write', () async {
    var ticks = 0;
    final sub = repo.changes.listen((_) => ticks++);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 1);
    await f.zone('Another');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 2);
    await sub.cancel();
  });
}
