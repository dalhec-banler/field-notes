import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/seed.dart';
import 'package:field_notes/desktop/desk_map_view.dart';
import 'package:field_notes/desktop/desktop_shell.dart';
import 'package:field_notes/desktop/export_workspace.dart';
import 'package:field_notes/desktop/settings_workspace.dart';
import 'package:field_notes/screens/record_detail_screen.dart';
import 'package:field_notes/services/app_prefs.dart';
import 'package:field_notes/services/review.dart';
import 'package:field_notes/theme/skin.dart';
import 'package:field_notes/theme/theme.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// The desk, driven end to end (Austin, 2026-09-04: "full ux ui audit of
/// the desktop app… keep testing"): boot the real shell on a fixture
/// journal, walk every workspace, rule on a pending edit, and photograph
/// each tab so the audit has eyes.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

Future<void> _loadFonts() async {
  Future<void> fam(String family, List<String> assets) async {
    final loader = FontLoader(family);
    for (final a in assets) {
      loader.addFont(rootBundle.load(a));
    }
    await loader.load();
  }

  await fam('ZillaSlab', [
    'assets/fonts/ZillaSlab-Medium.ttf',
    'assets/fonts/ZillaSlab-SemiBold.ttf',
    'assets/fonts/ZillaSlab-Bold.ttf',
  ]);
  await fam('Newsreader', [
    'assets/fonts/Newsreader-Light.ttf',
    'assets/fonts/Newsreader-Regular.ttf',
  ]);
  await fam('JetBrainsMono', [
    'assets/fonts/JetBrainsMono-Regular.ttf',
    'assets/fonts/JetBrainsMono-Medium.ttf',
  ]);
}

String _ring(double lng, double lat, double w, double h) => jsonEncode({
  'type': 'Polygon',
  'coordinates': [
    [
      [lng - w, lat - h],
      [lng + w, lat - h],
      [lng + w, lat + h],
      [lng - w, lat + h],
      [lng - w, lat - h],
    ],
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FieldNotesDb db;
  late AppPrefs prefs;
  late Property property;
  late String pendingObsId;

  setUpAll(() async {
    PackageInfo.setMockInitialValues(
      appName: 'Field Notes',
      packageName: 'io.nativeplanet.field_notes',
      version: '1.1.0',
      buildNumber: '2',
      buildSignature: '',
    );
    // Press skin: real family names for the loaded fonts, so goldens
    // carry readable type instead of the test binding's block glyphs.
    skin = pressSkin;
    PathProviderPlatform.instance = _FakePathProvider(
      Directory.systemTemp.createTempSync('fn-desk-test').path,
    );
    await _loadFonts();
  });

  setUp(() async {
    db = FieldNotesDb.forTesting();
    await seedFeatureTypesIfEmpty(db);
    prefs = AppPrefs.inMemory();
    final now = nowUtcIso();
    final propId = newId();
    const lng = -98.5470, lat = 30.8830;
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propId,
            name: 'Cedar Break Ranch',
            county: const Value('Lampasas'),
            state: const Value('TX'),
            boundaryGeojson: Value(_ring(lng, lat, 0.007, 0.006)),
            centroidLat: const Value(lat),
            centroidLng: const Value(lng),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    for (final (name, dx, dy) in [
      ('North Pasture', -0.0015, 0.0035),
      ('Creek Corridor', 0.0005, -0.0005),
    ]) {
      await db
          .into(db.zones)
          .insert(
            ZonesCompanion.insert(
              id: newId(),
              propertyId: propId,
              name: name,
              geojson: _ring(lng + dx, lat + dy, 0.004, 0.002),
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    final taxonId = newId();
    await db
        .into(db.taxa)
        .insert(
          TaxaCompanion.insert(
            id: taxonId,
            scientificName: 'Quercus macrocarpa',
            commonName: const Value('Bur Oak'),
            growthForm: const Value('tree'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    Future<String> obs({
      required String type,
      String? taxon,
      String by = 'local',
      double j = 0,
    }) async {
      final id = newId();
      await db
          .into(db.observations)
          .insert(
            ObservationsCompanion.insert(
              id: id,
              propertyId: propId,
              observedAt: now,
              localTz: 'CDT',
              lat: lat + j,
              lng: lng + j,
              gpsAccuracyM: const Value(4.0),
              observationType: Value(type),
              taxonId: Value(taxon),
              taxonConfidence: Value(
                taxon == null ? 'unidentified' : 'certain',
              ),
              notes: const Value('audit fixture'),
              createdBy: by,
              createdAt: now,
              updatedAt: now,
            ),
          );
      return id;
    }

    await obs(type: 'plant', taxon: taxonId, j: 0.0004);
    await obs(type: 'water', j: -0.0006);
    await obs(type: 'problem', j: 0.0011);
    pendingObsId = await obs(type: 'plant', taxon: taxonId, by: 'wylder');
    await ReviewService(db).markPending(
      propertyId: propId,
      entityType: 'observation',
      entityId: pendingObsId,
      author: 'wylder',
    );
    final types = await db.select(db.featureTypes).get();
    await db
        .into(db.features)
        .insert(
          FeaturesCompanion.insert(
            id: newId(),
            propertyId: propId,
            featureTypeId: types.first.id,
            name: const Value('Bluff spring'),
            geojson: jsonEncode({
              'type': 'Point',
              'coordinates': [lng + 0.001, lat - 0.001],
            }),
            lat: Value(lat - 0.001),
            lng: Value(lng + 0.001),
            currentCondition: const Value('good'),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    property = await (db.select(
      db.properties,
    )..where((p) => p.id.equals(propId))).getSingle();
  });

  tearDown(() async => db.close());

  /// Pump, let real async (drift queries, tile fetches) run for [ms], pump.
  Future<void> settle(WidgetTester tester, int ms) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump();
  }

  Future<void> boot(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1360, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(),
        home: DesktopShell(
          db: db,
          property: property,
          prefs: prefs,
          onSwitchProperty: (_) {},
        ),
      ),
    );
    // Let the map's tile fetches fail and the subject load settle.
    await settle(tester, 600);
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> tab(WidgetTester tester, String label) async {
    // Nav labels are MonoLabels — they render uppercased.
    await tester.tap(find.text(label.toUpperCase()).first);
    await settle(tester, 900);
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Photographs are an audit artifact, not a contract: they carry live
  /// dates and imagery timing, so they only render when asked —
  ///   flutter test test/desk_shell_test.dart \
  ///     --update-goldens --dart-define=DESK_SHOTS=1
  /// The default suite asserts behaviour and stays deterministic.
  const shots = bool.fromEnvironment('DESK_SHOTS');
  Future<void> shoot(WidgetTester tester, String name) async {
    if (!shots) return;
    await expectLater(
      find.byType(DesktopShell),
      matchesGoldenFile('goldens/desk/$name.png'),
    );
  }

  /// The Export bench renders its letter page off the main pump; wait for
  /// the composed page (its Image) before photographing or asserting.
  Future<void> waitForPlate(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      if (tester.any(find.byType(Image))) break;
      await settle(tester, 500);
    }
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Drift's stream queries schedule a zero-length close timer when their
  /// widgets go away; unmount and pump so it fires before the binding's
  /// pending-timer check.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
  }

  testWidgets('every workspace opens and photographs', (tester) async {
    await boot(tester);
    expect(find.byType(DeskMapWorkspace), findsOneWidget);
    await shoot(tester, '01-map');

    await tab(tester, 'Ledger');
    await shoot(tester, '02-ledger');

    await tab(tester, 'Grow');
    await shoot(tester, '03-grow');

    await tab(tester, 'Species');
    await shoot(tester, '04-species');

    await tab(tester, 'Review');
    expect(find.textContaining('RECORDS'), findsWidgets);
    await shoot(tester, '05-review');

    await tab(tester, 'Export');
    expect(find.byType(ExportWorkspace), findsOneWidget);
    await waitForPlate(tester);
    await shoot(tester, '06-export');

    await tab(tester, 'Settings');
    expect(find.byType(SettingsWorkspace), findsOneWidget);
    await shoot(tester, '07-settings');
    await unmount(tester);
  });

  testWidgets('workspaces build only when visited', (tester) async {
    await boot(tester);
    expect(find.byType(DeskMapWorkspace), findsOneWidget);
    // Export must not exist — or render, or fetch — before its first open.
    expect(find.byType(ExportWorkspace), findsNothing);
    await tab(tester, 'Export');
    expect(find.byType(ExportWorkspace), findsOneWidget);
    // And it survives leaving: IndexedStack keeps the composed page
    // offstage (so the finder must not skip offstage).
    await tab(tester, 'Ledger');
    expect(find.byType(ExportWorkspace, skipOffstage: false), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('desk map species panel opens the record', (tester) async {
    await boot(tester);
    // Two Bur Oak records group into one species row.
    await tester.tap(find.text('Bur Oak').first);
    await settle(tester, 300);
    // The opened card lists its sightings; tapping one opens the record.
    await tester.tap(find.textContaining(' · plant').first);
    await settle(tester, 600);
    expect(find.byType(RecordDetailScreen), findsOneWidget);
    await shoot(tester, '08-map-record');
    await unmount(tester);
  });

  testWidgets('review: approve a pending edit', (tester) async {
    await boot(tester);
    await tab(tester, 'Review');
    await tester.tap(find.text('PENDING 1'));
    await tester.pump();
    await tester.tap(find.text('Bur Oak').first);
    await settle(tester, 600);
    expect(find.textContaining('PENDING ·'), findsOneWidget);
    await shoot(tester, '09-review-pending');
    await tester.tap(find.text('APPROVE'));
    await settle(tester, 400);
    expect(find.textContaining('APPROVED'), findsWidgets);
    final item = await ReviewService(db).forEntity('observation', pendingObsId);
    expect(item?.state, 'approved');
    await unmount(tester);
  });

  testWidgets('export warns when record locations go on the file', (
    tester,
  ) async {
    await boot(tester);
    await tab(tester, 'Export');
    await waitForPlate(tester);
    expect(find.textContaining('not for the'), findsNothing);
    await tester.tap(find.text('Field records'));
    await tester.pump();
    await waitForPlate(tester);
    expect(find.textContaining('exact spot'), findsOneWidget);
    await shoot(tester, '10-export-records');
    await unmount(tester);
  });
}
