import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/repo/properties_repo.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

void main() {
  late FieldNotesDb db;
  late RepoFixture f;
  late PropertiesRepo repo;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    f = await RepoFixture.seed(db);
    repo = PropertiesRepo(db);
  });

  tearDown(() => db.close());

  Future<String> place(String name, {bool removed = false}) async {
    final id = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: id,
            name: name,
            deletedAt: Value(removed ? f.now : null),
            createdBy: 'local',
            createdAt: f.now,
            updatedAt: f.now,
          ),
        );
    return id;
  }

  test('byId', () async {
    expect((await repo.byId(f.propertyId))?.name, 'Cedar Break Ranch');
    expect(await repo.byId('nope'), isNull);
  });

  test('live is name-ordered and skips removed places', () async {
    await place('Bluff Lease');
    await place('Zed Tract', removed: true);
    expect(
      (await repo.live()).map((p) => p.name),
      ['Bluff Lease', 'Cedar Break Ranch'],
    );
  });

  test('changes fires on a property write', () async {
    var ticks = 0;
    final sub = repo.changes.listen((_) => ticks++);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 1);
    await place('New');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 2);
    await sub.cancel();
  });
}
