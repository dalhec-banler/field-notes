import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/seed.dart';
import 'package:field_notes/export/map_plate.dart';
import 'package:field_notes/export/plate_subject_loader.dart';
import 'package:field_notes/map/layers/layer_loader.dart';
import 'package:field_notes/map/layers/map_layers.dart';
import 'package:field_notes/map/record_ink.dart';
import 'package:field_notes/repo/observations_repo.dart';
import 'package:flutter_test/flutter_test.dart';

/// One layer model for every map (D-038 item 11): the loader builds the
/// same layer set the phone, the desk and the plate draw from, and the
/// plate's subject derived from it says exactly what the old loader said.
void main() {
  late FieldNotesDb db;
  late Property property;
  late MapLayerLoader loader;

  const now = '2026-09-10T12:00:00.000Z';

  String poly(List<List<double>> lnglat) => jsonEncode({
    'type': 'Polygon',
    'coordinates': [
      [...lnglat, lnglat.first],
    ],
  });

  final boundary = poly([
    [-98.06, 31.05],
    [-98.03, 31.05],
    [-98.03, 31.07],
    [-98.06, 31.07],
  ]);
  final riverStrip = poly([
    [-98.055, 31.055],
    [-98.045, 31.055],
    [-98.045, 31.065],
    [-98.055, 31.065],
  ]);
  final upland = poly([
    [-98.045, 31.055],
    [-98.035, 31.055],
    [-98.035, 31.065],
    [-98.045, 31.065],
  ]);
  final hiddenSlope = poly([
    [-98.06, 31.05],
    [-98.05, 31.05],
    [-98.05, 31.055],
    [-98.06, 31.055],
  ]);

  Future<void> record(
    String id, {
    required double lat,
    required double lng,
    String type = 'plant',
    String? taxon,
    String? zone,
    String? removal,
    String? notes,
    double? accuracy = 4.0,
    String observedAt = '2026-09-01T15:00:00.000Z',
    String propertyId = 'prop-1',
    String? deletedAt,
  }) => db
      .into(db.observations)
      .insert(
        ObservationsCompanion.insert(
          id: id,
          propertyId: propertyId,
          observedAt: observedAt,
          localTz: 'America/Chicago',
          lat: lat,
          lng: lng,
          gpsAccuracyM: Value(accuracy),
          observationType: Value(type),
          taxonId: Value(taxon),
          zoneId: Value(zone),
          removalStatus: Value(removal),
          notes: Value(notes),
          createdBy: 'local',
          createdAt: observedAt,
          updatedAt: observedAt,
          deletedAt: Value(deletedAt),
        ),
      );

  setUp(() async {
    db = FieldNotesDb.forTesting();
    await seedFeatureTypesIfEmpty(db);
    loader = MapLayerLoader(db);

    for (final (id, name) in [('prop-1', 'Test Place'), ('prop-2', 'Other')]) {
      await db
          .into(db.properties)
          .insert(
            PropertiesCompanion.insert(
              id: id,
              name: name,
              boundaryGeojson: Value(id == 'prop-1' ? boundary : null),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    property = await (db.select(
      db.properties,
    )..where((p) => p.id.equals('prop-1'))).getSingle();

    // Two zones that draw (inserted out of name order) and one hidden.
    for (final (id, name, geo, color, acres, hidden) in [
      ('zone-b', 'Upland', upland, null, null, 0),
      ('zone-a', 'River strip', riverStrip, '#2F5D8A', 12.5, 0),
      ('zone-h', 'Hidden slope', hiddenSlope, '#8B2E22', 3.0, 1),
    ]) {
      await db
          .into(db.zones)
          .insert(
            ZonesCompanion.insert(
              id: id,
              propertyId: 'prop-1',
              name: name,
              geojson: geo,
              colorHex: Value(color),
              areaAcres: Value(acres),
              hidden: Value(hidden),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }

    for (final (id, sci, common, form, nat) in [
      ('tax-oak', 'Quercus virginiana', 'Live oak', 'tree', 'native'),
      ('tax-jun', 'Juniperus ashei', 'Ashe juniper', 'tree', 'native'),
    ]) {
      await db
          .into(db.taxa)
          .insert(
            TaxaCompanion.insert(
              id: id,
              scientificName: sci,
              commonName: Value(common),
              growthForm: Value(form),
              nativity: Value(nat),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }

    // Records: a named plant in the HIDDEN zone (it still owns it), a
    // flagged juniper, a problem, a removed oak, a hand-placed water
    // record (null accuracy), and three that must not draw — no fix,
    // soft-deleted, another place.
    await record(
      'obs-1',
      lat: 31.0580,
      lng: -98.0520,
      taxon: 'tax-oak',
      zone: 'zone-h',
    );
    await record(
      'obs-2',
      lat: 31.0581,
      lng: -98.0521,
      taxon: 'tax-jun',
      removal: 'flagged',
      notes: 'Cut this winter.',
      observedAt: '2026-09-02T15:00:00.000Z',
    );
    await record(
      'obs-3',
      lat: 31.0660,
      lng: -98.0360,
      type: 'problem',
      notes: 'Headcut advancing.',
      observedAt: '2026-09-03T15:00:00.000Z',
    );
    await record(
      'obs-4',
      lat: 31.0600,
      lng: -98.0400,
      taxon: 'tax-oak',
      removal: 'removed',
      observedAt: '2026-08-20T15:00:00.000Z',
    );
    await record(
      'obs-5',
      lat: 31.0582,
      lng: -98.0522,
      type: 'water',
      accuracy: null,
    );
    await record('obs-nofix', lat: 0, lng: 0, type: 'water', accuracy: -1);
    await record(
      'obs-del',
      lat: 31.06,
      lng: -98.04,
      type: 'general',
      deletedAt: now,
    );
    await record('obs-other', lat: 31.06, lng: -98.04, propertyId: 'prop-2');

    // Photos: a primary thumbnail on the juniper, a plain attachment on the oak.
    for (final (mid, thumb, local) in [
      ('med-1', '/t/1.jpg', '/p/1.jpg'),
      ('med-2', null, '/p/2.jpg'),
    ]) {
      await db
          .into(db.media)
          .insert(
            MediaCompanion.insert(
              id: mid,
              propertyId: 'prop-1',
              mediaType: 'photo',
              thumbPath: Value(thumb),
              localPath: Value(local),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    for (final (lid, mid, obs, role) in [
      ('lnk-1', 'med-1', 'obs-2', 'primary'),
      ('lnk-2', 'med-2', 'obs-1', 'attachment'),
    ]) {
      await db
          .into(db.mediaLinks)
          .insert(
            MediaLinksCompanion.insert(
              id: lid,
              propertyId: 'prop-1',
              mediaId: mid,
              entityType: 'observation',
              entityId: obs,
              role: Value(role),
              createdAt: now,
            ),
          );
    }

    // A spring with no name of its own, and a named headcut.
    Future<String> typeId(String key) async => (await (db.select(
      db.featureTypes,
    )..where((t) => t.typeKey.equals(key))).getSingle()).id;
    await db
        .into(db.features)
        .insert(
          FeaturesCompanion.insert(
            id: 'feat-1',
            propertyId: 'prop-1',
            featureTypeId: await typeId('spring'),
            geojson: '{"type":"Point","coordinates":[-98.05,31.06]}',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.features)
        .insert(
          FeaturesCompanion.insert(
            id: 'feat-2',
            propertyId: 'prop-1',
            featureTypeId: await typeId('erosion_zone'),
            name: const Value('Headcut'),
            geojson: '{"type":"Point","coordinates":[-98.036,31.066]}',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );

    // One walked track with geometry, one still recording (none).
    for (final (tid, geo) in [
      (
        'trk-1',
        '{"type":"LineString","coordinates":[[-98.058,31.052],[-98.04,31.066]]}',
      ),
      ('trk-live', null),
    ]) {
      await db
          .into(db.tracks)
          .insert(
            TracksCompanion.insert(
              id: tid,
              propertyId: 'prop-1',
              startedAt: now,
              purpose: const Value('walk'),
              geojson: Value(geo),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }

    // A station that has been shot (bearing 90), and one never shot.
    for (final (pid, name, bearing) in [
      ('pp-1', 'Willow bar', 90.0),
      ('pp-0', 'Unshot', 0.0),
    ]) {
      await db
          .into(db.photoPoints)
          .insert(
            PhotoPointsCompanion.insert(
              id: pid,
              propertyId: 'prop-1',
              name: name,
              lat: 31.057,
              lng: -98.05,
              bearingDeg: bearing,
              focalLengthMm: const Value(26),
              viewExtentM: Value(pid == 'pp-1' ? 80 : null),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }

    // A monitoring protocol with one site.
    await db
        .into(db.protocols)
        .insert(
          ProtocolsCompanion.insert(
            id: 'proto-1',
            propertyId: 'prop-1',
            methodKey: 'cover_check',
            name: 'Cover check',
            siteKind: 'plot',
            fieldsJson: '[]',
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.protocolSites)
        .insert(
          ProtocolSitesCompanion.insert(
            id: 'site-1',
            propertyId: 'prop-1',
            protocolId: 'proto-1',
            name: 'Plot 1',
            lat: 31.059,
            lng: -98.051,
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
  });

  tearDown(() => db.close());

  test('the loader builds every layer, in draw order', () async {
    final set = await loader.load(property, withPhotos: true);
    expect(set.propertyName, 'Test Place');
    expect(set.layers.map((l) => l.kind).toList(), [
      MapLayerKind.imagery,
      MapLayerKind.zones,
      MapLayerKind.boundary,
      MapLayerKind.tracks,
      MapLayerKind.features,
      MapLayerKind.photoPoints,
      MapLayerKind.protocolSites,
      MapLayerKind.records,
    ]);
    expect(set.boundaryGeojson, boundary);
    expect(set.imagery, isNotNull);

    // Hidden zones stay off; the rest come in name order with their ink.
    expect(set.zones.map((z) => z.name).toList(), ['River strip', 'Upland']);
    final zones = set.layer<ZoneFills>()!;
    expect(zones.inkAt(0), 0xFF2F5D8A); // its own colour
    expect(zones.inkAt(1), zoneFillPalette[1]); // palette by position
    expect(set.zones[0].areaAcres, 12.5);
    expect(set.zones[1].areaAcres, isNotNull); // derived from the ring

    expect(set.tracks.map((t) => t.id), ['trk-1']);
    expect(set.features.map((f) => f.name).toList(), ['Spring', 'Headcut']);
    expect(set.features[0].featureClass, 'natural');
    expect(set.features[1].ink, featureClassInk('problem'));

    final stations = set.stations;
    expect(stations.map((s) => s.id).toSet(), {'pp-1', 'pp-0'});
    final shot = stations.firstWhere((s) => s.id == 'pp-1');
    expect(shot.hasView, isTrue);
    expect(shot.viewExtentM, 80);
    expect(shot.wedge.length, 15); // station, 13 arc points, station
    expect(shot.axis.length, 2);
    expect(stations.firstWhere((s) => s.id == 'pp-0').hasView, isFalse);

    expect(set.sites.map((s) => s.name), ['Plot 1']);
  });

  test('records: located and live only, with the mark they wear', () async {
    final set = await loader.load(property, withPhotos: true);
    final byId = {for (final r in set.records) r.id!: r};
    expect(byId.keys.toSet(), {'obs-1', 'obs-2', 'obs-3', 'obs-4', 'obs-5'});

    final juniper = byId['obs-2']!;
    expect(juniper.removal, 'flagged');
    expect(juniper.label, 'Ashe juniper');
    expect(juniper.growthForm, 'tree');
    expect(juniper.kind, 'tree');
    expect(juniper.mark.shape, RecordShape.circle);
    expect(juniper.nativity, 'native');
    expect(juniper.notes, 'Cut this winter.');
    expect(juniper.photoPath, '/t/1.jpg'); // the primary's thumbnail
    expect(juniper.realm, RecordRealm.species);

    expect(byId['obs-1']!.photoPath, '/p/2.jpg');
    expect(byId['obs-1']!.zoneId, 'zone-h'); // a hidden zone still owns it

    final problem = byId['obs-3']!;
    expect(problem.label, isNull);
    expect(problem.kind, 'problem');
    expect(problem.mark.shape, RecordShape.triangle);
    expect(problem.mark.argb, 0xFF8B2E22);
    expect(problem.realm, RecordRealm.problem);

    expect(byId['obs-4']!.removal, 'removed');
    expect(byId['obs-5']!.mark.argb, recordMarks['water']!.argb);

    // The maps skip the photo queries; the paths simply stay null.
    final light = await loader.load(property);
    expect(light.records.every((r) => r.photoPath == null), isTrue);
  });

  test('clusters group at a zoom the way the phone and desk badge', () async {
    final set = await loader.load(property);
    // Wide out, one badge holds everything.
    final far = set.clustersAt(6);
    expect(far.cells.length, 1);
    expect(far.cells.single.isCluster, isTrue);
    expect(far.cells.single.members.length, 5);
    // Close in, the three neighbours still share a cell; the rest stand alone.
    final mid = set.clustersAt(15);
    final sizes = mid.cells.map((c) => c.members.length).toList()..sort();
    expect(sizes, [1, 1, 3]);
    final trio = mid.clusters.single;
    expect(trio.ids.toSet(), {'obs-1', 'obs-2', 'obs-5'});
    final (lat, lng) = trio.centre;
    expect(lat, closeTo(31.0581, 1e-9));
    expect(lng, closeTo(-98.0521, 1e-9));
    expect(mid.singles.map((r) => r.id).toSet(), {'obs-3', 'obs-4'});
    // All the way in, every record is its own mark.
    expect(set.clustersAt(20).cells.length, 5);
    expect(set.clustersAt(20).clusters, isEmpty);
  });

  test('the ledger filter narrows the records the loader hands back', () async {
    Future<Set<String>> ids(LedgerQuery q) async => {
      for (final r in (await loader.load(property, filter: q)).records) r.id!,
    };
    expect(await ids(const LedgerQuery(flagged: true)), {'obs-2'});
    expect(await ids(const LedgerQuery(type: 'problem')), {'obs-3'});
    expect(await ids(const LedgerQuery(taxonId: 'tax-oak')), {
      'obs-1',
      'obs-4',
    });
    expect(await ids(const LedgerQuery(zoneId: 'zone-h')), {'obs-1'});
    expect(
      await ids(
        const LedgerQuery(
          fromUtc: '2026-09-02T00:00:00.000Z',
          toUtc: '2026-09-03T00:00:00.000Z',
        ),
      ),
      {'obs-2'},
    );
    expect(await ids(const LedgerQuery()), hasLength(5));
  });

  test('visibility switches layers off without losing them', () async {
    final set = await loader.load(
      property,
      visibility: const LayerVisibility(zones: false, records: false),
    );
    final on = set.visible.map((l) => l.kind).toSet();
    expect(on, isNot(contains(MapLayerKind.zones)));
    expect(on, isNot(contains(MapLayerKind.records)));
    expect(on, contains(MapLayerKind.boundary));
    expect(set.zones, hasLength(2)); // still there, just not drawn
    expect(set.visibility.isOn(MapLayerKind.clusters), isFalse); // follows records
    expect(
      set.withVisibility(const LayerVisibility()).visibility.isOn(
        MapLayerKind.zones,
      ),
      isTrue,
    );
  });

  test('watch fires once, then again when a drawn table changes', () async {
    final sets = <MapLayerSet>[];
    final sub = loader.watch(property).listen(sets.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(sets, hasLength(1));
    expect(sets.single.records, hasLength(5));
    await record('obs-new', lat: 31.062, lng: -98.045, type: 'soil');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sets.length, greaterThanOrEqualTo(2));
    expect(sets.last.records.map((r) => r.id), contains('obs-new'));
    await sub.cancel();
  });

  test('the plate subject from the set says what the loader said', () async {
    // What loadPlateSubject produced before the layer model existed,
    // captured verbatim: the plate's words must not move.
    const snapshot =
        '{"property":"Test Place","boundary":"{\\"type\\":\\"Polygon\\",\\"coordinates\\":[[[-98.06,31.05],[-98.03,31.05],[-98.03,31.07],[-98.06,31.07],[-98.06,31.05]]]}","zones":[{"name":"River strip","geojson":"{\\"type\\":\\"Polygon\\",\\"coordinates\\":[[[-98.055,31.055],[-98.045,31.055],[-98.045,31.065],[-98.055,31.065],[-98.055,31.055]]]}","colorHex":"#2F5D8A","areaAcres":12.5},{"name":"Upland","geojson":"{\\"type\\":\\"Polygon\\",\\"coordinates\\":[[[-98.045,31.055],[-98.035,31.055],[-98.035,31.065],[-98.045,31.065],[-98.045,31.055]]]}","colorHex":null,"areaAcres":262.3}],"features":[{"id":"feat-1","name":"Spring","class":"natural","geojson":"{\\"type\\":\\"Point\\",\\"coordinates\\":[-98.05,31.06]}"},{"id":"feat-2","name":"Headcut","class":"problem","geojson":"{\\"type\\":\\"Point\\",\\"coordinates\\":[-98.036,31.066]}"}],"records":[{"id":"obs-1","lat":31.058,"lng":-98.052,"type":"plant","label":"Live oak","observedAt":"2026-09-01T15:00:00.000Z","removal":null,"nativity":"native","notes":null,"photoPath":"/p/2.jpg"},{"id":"obs-2","lat":31.0581,"lng":-98.0521,"type":"plant","label":"Ashe juniper","observedAt":"2026-09-02T15:00:00.000Z","removal":"flagged","nativity":"native","notes":"Cut this winter.","photoPath":"/t/1.jpg"},{"id":"obs-5","lat":31.0582,"lng":-98.0522,"type":"water","label":null,"observedAt":"2026-09-01T15:00:00.000Z","removal":null,"nativity":null,"notes":null,"photoPath":null},{"id":"obs-4","lat":31.06,"lng":-98.04,"type":"plant","label":"Live oak","observedAt":"2026-08-20T15:00:00.000Z","removal":"removed","nativity":"native","notes":null,"photoPath":null},{"id":"obs-3","lat":31.066,"lng":-98.036,"type":"problem","label":null,"observedAt":"2026-09-03T15:00:00.000Z","removal":null,"nativity":null,"notes":"Headcut advancing.","photoPath":null}],"tracks":[{"geojson":"{\\"type\\":\\"LineString\\",\\"coordinates\\":[[-98.058,31.052],[-98.04,31.066]]}","label":"walk"}]}';

    final old = describeSubject(await loadPlateSubject(db, property));
    expect(old, snapshot);

    final set = await loader.load(property, withPhotos: true);
    expect(describeSet(set), snapshot);
    expect(describeSubject(PlateSubject.of(set)), snapshot);
    // The plate renderer walks the set itself — same layers, same order.
    expect(PlateSubject.of(set).layers, same(set));
  });
}

/// A plate subject, flattened to the words the plate and its documents
/// read from it — so two ways of building one can be compared exactly.
String describeSubject(PlateSubject s) => jsonEncode({
  'property': s.propertyName,
  'boundary': s.boundaryGeojson,
  'zones': [
    for (final z in s.zones)
      {
        'name': z.name,
        'geojson': z.geojson,
        'colorHex': z.colorHex,
        'areaAcres': _round(z.areaAcres),
      },
  ],
  'features': [
    for (final f in s.features)
      {
        'id': f.id,
        'name': f.name,
        'class': f.featureClass,
        'geojson': f.geojson,
      },
  ],
  'records': [
    for (final r in s.records)
      {
        'id': r.id,
        'lat': r.lat,
        'lng': r.lng,
        'type': r.type,
        'label': r.label,
        'observedAt': r.observedAt,
        'removal': r.removal,
        'nativity': r.nativity,
        'notes': r.notes,
        'photoPath': r.photoPath,
      },
  ],
  'tracks': [
    for (final t in s.tracks) {'geojson': t.geojson, 'label': t.label},
  ],
});

/// The same words, read straight off a layer set.
String describeSet(MapLayerSet s) => jsonEncode({
  'property': s.propertyName,
  'boundary': s.boundaryGeojson,
  'zones': [
    for (final z in s.zones)
      {
        'name': z.name,
        'geojson': z.geojson,
        'colorHex': z.colorHex,
        'areaAcres': _round(z.areaAcres),
      },
  ],
  'features': [
    for (final f in s.features)
      {
        'id': f.id,
        'name': f.name,
        'class': f.featureClass,
        'geojson': f.geojson,
      },
  ],
  'records': [
    for (final r in s.records)
      {
        'id': r.id,
        'lat': r.lat,
        'lng': r.lng,
        'type': r.type,
        'label': r.label,
        'observedAt': r.observedAt,
        'removal': r.removal,
        'nativity': r.nativity,
        'notes': r.notes,
        'photoPath': r.photoPath,
      },
  ],
  'tracks': [
    for (final t in s.tracks) {'geojson': t.geojson, 'label': t.label},
  ],
});

double? _round(double? v) => v == null ? null : (v * 10).round() / 10;
