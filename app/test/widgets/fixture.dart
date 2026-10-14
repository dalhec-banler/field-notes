import 'dart:io';

import 'package:field_notes/app_scope.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/seed.dart';
import 'package:field_notes/repo/repos.dart';
import 'package:field_notes/services/app_prefs.dart';
import 'package:field_notes/services/location_hub.dart';
import 'package:field_notes/services/map_jump.dart';
import 'package:field_notes/services/record_filter.dart';
import 'package:field_notes/services/track_recorder.dart';
import 'package:field_notes/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../repo/fixture.dart';

/// The hero-flow widget fixture (D-038 item 8), the same shape as
/// test/desk_shell_test.dart: a fake path provider under a temp root,
/// mocked package info, the app's fonts, an in-memory database seeded
/// with one place, two zones, one species and whatever records a test
/// adds, and an [AppScope] around the widget under test with its own
/// filter and jump notifier so tests never share state.
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

class WidgetFixture {
  WidgetFixture._(this.db, this.seed, this.prefs, this.property);

  final FieldNotesDb db;
  final RepoFixture seed;
  final AppPrefs prefs;
  final Property property;
  final recordFilter = RecordFilter();
  final mapJump = ValueNotifier<MapJump?>(null);
  late final hub = LocationHub();
  late final recorder = TrackRecorder(db, hub);

  /// The same repos the scope hands the screens, for assertions.
  late final observations = ObservationsRepo(db);

  /// Once per test file: platform fakes and fonts.
  static Future<Directory> installPlatform() async {
    PackageInfo.setMockInitialValues(
      appName: 'Field Notes',
      packageName: 'io.nativeplanet.field_notes',
      version: '1.1.0',
      buildNumber: '2',
      buildSignature: '',
    );
    final root = Directory.systemTemp.createTempSync('fn-widget-test');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    _mockPlugins();
    await _loadFonts();
    return root;
  }

  /// The plugins capture constructs or asks on open, answered on the host:
  /// no camera permission (so the shutter step offers NO PHOTO), a voice
  /// recorder that accepts create/dispose, and speech that is unavailable.
  /// Geolocator stays unmocked: LocationHub already treats a missing
  /// plugin as "no fix", which is the path under test.
  static void _mockPlugins() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async {
        if (call.method == 'requestPermissions') {
          // camera (1) → denied (0)
          return <int, int>{1: 0};
        }
        if (call.method == 'checkPermissionStatus') return 0;
        return null;
      },
    );
    m.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async => null,
    );
    m.setMockMethodCallHandler(
      const MethodChannel('plugin.csdcorp.com/speech_to_text'),
      (call) async => call.method == 'initialize' ? false : null,
    );
  }

  static Future<WidgetFixture> open() async {
    final db = FieldNotesDb.forTesting();
    await seedFeatureTypesIfEmpty(db);
    final seed = await RepoFixture.seed(db);
    final prefs = AppPrefs.inMemory();
    prefs.activePropertyId = seed.propertyId;
    final property = await (db.select(
      db.properties,
    )..where((p) => p.id.equals(seed.propertyId))).getSingle();
    return WidgetFixture._(db, seed, prefs, property);
  }

  Future<void> close() => db.close();

  /// The widget under test, inside the scope and a MaterialApp.
  Widget app(Widget home) => AppScope(
    db: db,
    opLog: null,
    locationHub: hub,
    trackRecorder: recorder,
    recordFilter: recordFilter,
    mapJump: mapJump,
    prefs: prefs,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      home: home,
    ),
  );

  /// A host page with one OPEN button that pushes [route] and keeps the
  /// result, for screens that pop themselves (capture, record detail).
  Widget host<T>(Widget Function() route, void Function(T?) onResult) =>
      app(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  final r = await Navigator.of(context).push<T>(
                    MaterialPageRoute(builder: (_) => route()),
                  );
                  onResult(r);
                },
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      );
}

/// A phone-width, very tall surface so every control on a scrolling page
/// is on screen and tappable without scrolling choreography.
Future<void> tall(
  WidgetTester tester, {
  double height = 2400,
  double width = 430,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// Pump, let real async (drift, platform channels) run for [ms], then move
/// the fake clock far enough to finish any route or sheet transition — a
/// pushed page or a modal sheet otherwise sits mid-slide, and taps on it
/// land beside their targets.
Future<void> settle(WidgetTester tester, [int ms = 300]) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Settle repeatedly until [finder] matches, up to [timeout] of real time
/// — for work that runs off the fake clock (file I/O, hashing, the backup
/// store) and takes as long as the machine is busy.
Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final until = DateTime.now().add(timeout);
  while (!tester.any(finder)) {
    if (DateTime.now().isAfter(until)) {
      fail('timed out waiting for $finder');
    }
    await settle(tester, 200);
  }
}

/// Pump [widget] under the fixture, on a tall phone surface, and make sure
/// it is unmounted before the database closes — a test that fails with the
/// tree still up would otherwise leave drift streams open and `db.close()`
/// waiting on them forever.
Future<void> mount(
  WidgetTester tester,
  Widget widget, {
  double height = 2400,
  double width = 430,
}) async {
  await tall(tester, height: height, width: width);
  addTearDown(() => unmount(tester));
  await tester.pumpWidget(widget);
}

/// Drift's stream queries schedule a zero-length close timer when their
/// widgets go away; unmount and pump so it fires before the binding's
/// pending-timer check.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 20));
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
