import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/repo/observations_repo.dart';
import 'package:field_notes/services/env_context.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

void main() {
  late FieldNotesDb db;
  late RepoFixture f;
  late ObservationsRepo repo;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    f = await RepoFixture.seed(db);
    repo = ObservationsRepo(db);
  });

  tearDown(() => db.close());

  test('byId and single', () async {
    final id = await f.record(type: 'water');
    expect((await repo.byId(id))?.observationType, 'water');
    expect((await repo.single(id)).id, id);
    expect(await repo.byId('nope'), isNull);
    expect(repo.single('nope'), throwsStateError);
  });

  group('watchLedger', () {
    test('newest first, live rows only, and follows writes', () async {
      final old = await f.record(observedAt: '2026-01-01T12:00:00.000Z');
      final recent = await f.record(observedAt: '2026-09-01T12:00:00.000Z');
      final gone = await f.record(observedAt: '2026-10-01T12:00:00.000Z');
      await repo.softDelete(gone);
      final stream = repo.watchLedger(f.propertyId, const LedgerQuery());
      final first = await stream.first;
      expect(first.map((o) => o.id), [recent, old]);

      final expectation = expectLater(
        stream.map((rows) => rows.length),
        emitsThrough(3),
      );
      await f.record(observedAt: '2026-10-02T12:00:00.000Z');
      await expectation;
    });

    test('narrows by zone, type, taxon and flagged', () async {
      final a = await f.record(
        type: 'plant',
        taxonId: f.burOakId,
        zoneId: f.northZoneId,
        removalStatus: 'flagged',
      );
      final b = await f.record(type: 'plant', zoneId: f.creekZoneId);
      final c = await f.record(type: 'water');
      Future<List<String>> ids(LedgerQuery q) async =>
          (await repo.watchLedger(f.propertyId, q).first)
              .map((o) => o.id)
              .toList();

      expect(await ids(const LedgerQuery(type: 'plant')), containsAll([a, b]));
      expect(await ids(const LedgerQuery(type: 'plant')), isNot(contains(c)));
      expect(await ids(LedgerQuery(zoneId: f.creekZoneId)), [b]);
      expect(await ids(LedgerQuery(taxonId: f.burOakId)), [a]);
      expect(await ids(const LedgerQuery(flagged: true)), [a]);
    });

    test('date bounds are half-open on observed_at', () async {
      final inside = await f.record(observedAt: '2026-05-10T03:00:00.000Z');
      await f.record(observedAt: '2026-05-11T00:00:00.000Z'); // == to
      await f.record(observedAt: '2026-05-09T23:59:59.000Z'); // < from
      final rows = await repo
          .watchLedger(
            f.propertyId,
            const LedgerQuery(
              fromUtc: '2026-05-10T00:00:00.000Z',
              toUtc: '2026-05-11T00:00:00.000Z',
            ),
          )
          .first;
      expect(rows.map((o) => o.id), [inside]);
    });
  });

  test('located leaves out the -1 "no fix" rows', () async {
    final fixed = await f.record();
    final placed = await f.record(accuracy: null);
    await f.record(accuracy: -1);
    final rows = await repo.located(f.propertyId);
    expect(rows.map((o) => o.id), unorderedEquals([fixed, placed]));
  });

  test('meanPosition averages every live row; locatedExtent only fixes', () async {
    expect(await repo.meanPosition(f.propertyId), isNull);
    expect((await repo.locatedExtent(f.propertyId)).count, 0);
    await f.record(j: 0.002);
    await f.record(j: -0.002);
    await f.record(j: 0.010, accuracy: -1);
    final mean = await repo.meanPosition(f.propertyId);
    expect(mean!.$1, closeTo(RepoFixture.lat + 0.010 / 3, 1e-9));
    final extent = await repo.locatedExtent(f.propertyId);
    expect(extent.count, 2);
    expect(extent.meanLat, closeTo(RepoFixture.lat, 1e-9));
    expect(extent.minLng, closeTo(RepoFixture.lng - 0.002, 1e-9));
    expect(extent.maxLng, closeTo(RepoFixture.lng + 0.002, 1e-9));
  });

  test('pins join the species and skip unlocated rows', () async {
    final named = await f.record(type: 'plant', taxonId: f.burOakId);
    final plain = await f.record(type: 'problem', removalStatus: 'flagged');
    await f.record(accuracy: -1);
    final pins = await repo.pins(f.propertyId);
    expect(pins.map((p) => p.id), unorderedEquals([named, plain]));
    final oak = pins.firstWhere((p) => p.id == named);
    expect(oak.species, 'Bur Oak');
    expect(oak.growthForm, 'tree');
    expect(oak.taxonId, f.burOakId);
    final problem = pins.firstWhere((p) => p.id == plain);
    expect(problem.species, isNull);
    expect(problem.removalStatus, 'flagged');
    expect(problem.type, 'problem');
  });

  test('pinChanges fires on listen and on a record or taxon write', () async {
    var ticks = 0;
    final sub = repo.pinChanges.listen((_) => ticks++);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 1);
    await f.record();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 2);
    await (db.update(db.taxa)..where((t) => t.id.equals(f.burOakId))).write(
      const TaxaCompanion(commonName: Value('Burr Oak')),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ticks, 3);
    await sub.cancel();
  });

  test('nearby: within 50 m, nearest first, never itself or unlocated', () async {
    final here = await f.record();
    final close = await f.record(j: 0.0001); // ~15 m
    final farther = await f.record(j: 0.0003); // ~45 m
    await f.record(j: 0.0009); // ~135 m
    await f.record(j: 0.0001, accuracy: -1);
    final obs = await repo.single(here);
    final out = await repo.nearby(obs);
    expect(out.map((e) => e.$1.id), [close, farther]);
    expect(out.first.$2, lessThan(out.last.$2));

    final unlocated = await repo.single(await f.record(accuracy: -1));
    expect(await repo.nearby(unlocated), isEmpty);
  });

  test('envContext reads the row a record points at', () async {
    final envId = await EnvContextService(db).createStale(
      propertyId: f.propertyId,
      lat: RepoFixture.lat,
      lng: RepoFixture.lng,
      resolvedFor: '2026-10-13',
    );
    final env = await repo.envContext(envId);
    expect(env?.isStale, 1);
    expect(await repo.envContext('nope'), isNull);
  });

  group('condition logs', () {
    Future<String> log(String obsId, String on, String condition) async {
      final id = newId();
      await db
          .into(db.conditionLogs)
          .insert(
            ConditionLogsCompanion.insert(
              id: id,
              propertyId: f.propertyId,
              observationId: obsId,
              observedAt: on,
              condition: condition,
              createdBy: 'local',
              createdAt: f.now,
              updatedAt: f.now,
            ),
          );
      return id;
    }

    test('watch is newest first and drops soft-deleted entries', () async {
      final obs = await f.record();
      final older = await log(obs, '2026-01-01', 'poor');
      final newer = await log(obs, '2026-06-01', 'good');
      expect(
        (await repo.watchConditionLogs(obs).first).map((l) => l.id),
        [newer, older],
      );
      await repo.softDeleteConditionLog(older);
      expect(
        (await repo.watchConditionLogs(obs).first).map((l) => l.id),
        [newer],
      );
    });

    test('update writes the four fields and bumps updated_at', () async {
      final obs = await f.record();
      final id = await log(obs, '2026-01-01', 'poor');
      await repo.updateConditionLog(
        id,
        observedAt: '2026-02-02',
        condition: 'fair',
        actionTaken: 'cleared brush',
        notes: null,
      );
      final row = (await repo.watchConditionLogs(obs).first).single;
      expect(row.observedAt, '2026-02-02');
      expect(row.condition, 'fair');
      expect(row.actionTaken, 'cleared brush');
      expect(row.updatedAt.compareTo(f.now), greaterThanOrEqualTo(0));
    });
  });

  test('setRemoval flags, stamps the day on removed, and clears', () async {
    final id = await f.record();
    await repo.setRemoval(id, 'flagged');
    var row = await repo.single(id);
    expect(row.removalStatus, 'flagged');
    expect(row.removedOn, isNull);
    await repo.setRemoval(id, 'removed');
    row = await repo.single(id);
    expect(row.removalStatus, 'removed');
    expect(row.removedOn, nowUtcIso().substring(0, 10));
    await repo.setRemoval(id, null);
    row = await repo.single(id);
    expect(row.removalStatus, isNull);
    expect(row.removedOn, isNull);
  });

  test('moveTo: placed-by-hand accuracy and the zone re-derived', () async {
    final id = await f.record(zoneId: f.creekZoneId);
    final obs = await repo.single(id);
    // Into North Pasture (its ring is centred 0.0035 north).
    await repo.moveTo(
      obs,
      lat: RepoFixture.lat + 0.0035,
      lng: RepoFixture.lng - 0.0015,
    );
    var moved = await repo.single(id);
    expect(moved.gpsAccuracyM, isNull);
    expect(moved.zoneId, f.northZoneId);
    // And out of every zone: the zone clears rather than sticking.
    await repo.moveTo(moved, lat: RepoFixture.lat + 0.05, lng: RepoFixture.lng);
    moved = await repo.single(id);
    expect(moved.zoneId, isNull);
  });

  test('softDelete and applyEdit reach the row', () async {
    final id = await f.record(notes: 'before');
    await repo.applyEdit(
      id,
      taxonId: f.burOakId,
      taxonConfidence: 'probable',
      observationType: 'plant',
      observedAt: '2026-03-03T12:00:00.000Z',
      notes: '  after  ',
    );
    var row = await repo.single(id);
    expect(row.notes, 'after');
    expect(row.taxonId, f.burOakId);
    expect(row.observationType, 'plant');
    await repo.softDelete(id);
    row = await repo.single(id);
    expect(row.deletedAt, isNotNull);
  });
}
