import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/repo/photo_points_repo.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

void main() {
  late FieldNotesDb db;
  late RepoFixture f;
  late PhotoPointsRepo repo;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    f = await RepoFixture.seed(db);
    repo = PhotoPointsRepo(db);
  });

  tearDown(() => db.close());

  test('create writes the station with the capture defaults', () async {
    final obs = await f.record();
    final media = await f.media(entityId: obs);
    final id = await repo.create(
      propertyId: f.propertyId,
      name: 'Bur Oak',
      lat: RepoFixture.lat,
      lng: RepoFixture.lng,
      bearingDeg: 120,
      subject: 'Bur Oak',
      referenceMediaId: media,
      now: '2026-10-13T12:00:00.000Z',
    );
    final p = await repo.byId(id);
    expect(p, isNotNull);
    expect(p!.cadenceDays, 90);
    expect(p.focalLengthMm, 26);
    expect(p.viewExtentM, 60);
    expect(p.bearingDeg, 120);
    expect(p.referenceMediaId, media);
    expect(p.createdAt, '2026-10-13T12:00:00.000Z');
    expect(p.createdBy, 'local');
  });

  test('on lists live stations; anchoredBy finds one by its frame', () async {
    final obs = await f.record();
    final frame = await f.media(entityId: obs);
    final a = await repo.create(
      propertyId: f.propertyId,
      name: 'A',
      lat: RepoFixture.lat,
      lng: RepoFixture.lng,
      bearingDeg: 0,
      referenceMediaId: frame,
    );
    final b = await repo.create(
      propertyId: f.propertyId,
      name: 'B',
      lat: RepoFixture.lat,
      lng: RepoFixture.lng,
      bearingDeg: 0,
    );
    await (db.update(db.photoPoints)..where((p) => p.id.equals(b))).write(
      PhotoPointsCompanion(deletedAt: Value(f.now)),
    );
    expect((await repo.on(f.propertyId)).map((p) => p.id), [a]);
    expect((await repo.anchoredBy([frame, 'other']))?.id, a);
    expect(await repo.anchoredBy(const []), isNull);
    expect(await repo.anchoredBy(['other']), isNull);
  });

  test('changes fires on a station write', () async {
    var ticks = 0;
    final sub = repo.changes.listen((_) => ticks++);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 1);
    await repo.create(
      propertyId: f.propertyId,
      name: 'C',
      lat: RepoFixture.lat,
      lng: RepoFixture.lng,
      bearingDeg: 0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 2);
    await sub.cancel();
  });
}
