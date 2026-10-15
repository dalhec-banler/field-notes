import 'package:field_notes/db/database.dart';
import 'package:field_notes/protocols/protocol_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stake with no visits can be pulled; one with history is kept and
/// retired instead, because the record outliving the question is the whole
/// point of monitoring.
void main() {
  late FieldNotesDb db;
  late ProtocolService svc;
  late String propId;

  setUp(() async {
    db = FieldNotesDb.forTesting();
    svc = ProtocolService(db);
    propId = newId();
    final now = nowUtcIso();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propId,
            name: 'Test',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await svc.ensureTemplates(propId);
  });

  tearDown(() => db.close());

  Future<ProtocolSite> aStake() async {
    final protocol = (await svc.protocolsFor(
      propId,
    )).firstWhere((p) => p.methodKey == 'brush_count');
    return svc.createSite(
      protocol: protocol,
      name: 'Stake 1',
      lat: 31.06,
      lng: -98.05,
    );
  }

  test('a stake nobody has visited is pulled, and leaves the map', () async {
    final site = await aStake();
    expect((await svc.sitesFor(propId)).length, 1);

    await svc.deleteSite(site.id);

    expect(await svc.sitesFor(propId), isEmpty);
    expect(await svc.sitesFor(propId, includeRetired: true), isEmpty);
    final row = await (db.select(
      db.protocolSites,
    )..where((s) => s.id.equals(site.id))).getSingle();
    expect(row.deletedAt, isNotNull, reason: 'soft delete, so it travels');
  });

  test('a stake with a visit refuses, and keeps its history', () async {
    final site = await aStake();
    final protocol = (await svc.protocolsFor(
      propId,
    )).firstWhere((p) => p.id == site.protocolId);
    await svc.saveRun(
      protocol: protocol,
      site: site,
      values: {
        'plant': [
          {'species': 'ashe juniper', 'size': '2'},
        ],
      },
      actualLat: 31.06,
      actualLng: -98.05,
      gpsAccuracyM: 4,
    );

    await expectLater(() => svc.deleteSite(site.id), throwsStateError);
    expect((await svc.sitesFor(propId)).length, 1);
  });
}
