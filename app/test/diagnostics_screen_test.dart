import 'dart:io';

import 'package:field_notes/db/database.dart';
import 'package:field_notes/desktop/settings_workspace.dart';
import 'package:field_notes/screens/diagnostics_screen.dart';
import 'package:field_notes/services/app_prefs.dart';
import 'package:field_notes/services/diag.dart';
import 'package:field_notes/tabs/settings_tab.dart';
import 'package:field_notes/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// The Diagnostics screen: the ring newest first, COPY ALL onto the
/// clipboard, CLEAR behind a confirm — and the row that reaches it from
/// Settings on both the phone and the desk.
///
/// Diag writes its file with real IO. A widget test runs in a fake-async
/// zone, so those writes only complete inside [WidgetTester.runAsync];
/// `settle` below is the same pattern the desk shell test uses for drift.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Field Notes',
      packageName: 'io.nativeplanet.field_notes',
      version: '1.5.1',
      buildNumber: '11',
      buildSignature: '',
    );
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('fn-diag-screen');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    Diag.resetForTesting();
    Diag.directoryOverride = root;
  });

  tearDown(() {
    // No flush here: a write queued in the fake zone never completes
    // outside it. resetForTesting drops the chain.
    Diag.directoryOverride = null;
    Diag.resetForTesting();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget host(Widget child) => MaterialApp(theme: appTheme(), home: child);

  /// Pump, let real async (file writes, drift) run for [ms], pump.
  Future<void> settle(WidgetTester tester, int ms) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump();
  }

  testWidgets('empty ring says so and disables copy and clear', (tester) async {
    await tester.pumpWidget(host(const DiagnosticsScreen()));
    await tester.pump();
    expect(
      find.text('Nothing has gone wrong that the app noticed.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'COPY ALL'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'CLEAR'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('entries list newest first with where and message', (
    tester,
  ) async {
    Diag.log('first thing', where: 'A.one');
    Diag.report(StateError('second thing'), StackTrace.current, where: 'B.two');
    await tester.pumpWidget(host(const DiagnosticsScreen()));
    await tester.pump();
    final second = tester.getTopLeft(find.textContaining('second thing'));
    final first = tester.getTopLeft(find.textContaining('first thing'));
    expect(second.dy, lessThan(first.dy), reason: 'newest on top');
    // Labels render through MonoLabel, which uppercases.
    expect(find.text('B.TWO'), findsOneWidget);
    expect(find.text('A.ONE'), findsOneWidget);
    expect(find.textContaining('2 ENTRIES'), findsOneWidget);
  });

  testWidgets('COPY ALL puts the whole dump on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    Diag.log('alpha', where: 'T.copy');
    Diag.report(ArgumentError('beta'), StackTrace.current, where: 'T.copy');
    await tester.pumpWidget(host(const DiagnosticsScreen()));
    await tester.pump();
    await tester.tap(find.text('COPY ALL'));
    await tester.pump();
    expect(copied, isNotNull);
    expect(copied, contains('alpha'));
    expect(copied, contains('beta'));
    expect(copied!.indexOf('beta'), lessThan(copied!.indexOf('alpha')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('COPIED · 2 ENTRIES'), findsOneWidget);
  });

  testWidgets('CLEAR asks first, then empties the ring', (tester) async {
    Diag.log('gone soon', where: 'T.clear');
    await tester.pumpWidget(host(const DiagnosticsScreen()));
    await settle(tester, 50);
    await tester.tap(find.text('CLEAR'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('CLEAR DIAGNOSTICS?'), findsOneWidget);
    // Decline keeps everything.
    await tester.tap(find.text('CANCEL'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('gone soon'), findsOneWidget);
    expect(Diag.length, 1);
    // Confirm empties it. The clear awaits the file; let real IO run.
    await tester.tap(find.text('CLEAR').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, 'CLEAR'));
    // Several hops of real IO, each handed back to the fake zone by a pump.
    for (var i = 0; i < 8; i++) {
      await settle(tester, 40);
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(Diag.length, 0);
    expect(find.textContaining('gone soon'), findsNothing);
    expect(
      find.text('Nothing has gone wrong that the app noticed.'),
      findsOneWidget,
    );
  });

  group('reached from Settings', () {
    late FieldNotesDb db;
    late AppPrefs prefs;
    late Property property;

    setUp(() async {
      db = FieldNotesDb.forTesting();
      prefs = AppPrefs.inMemory();
      final now = nowUtcIso();
      final id = newId();
      await db
          .into(db.properties)
          .insert(
            PropertiesCompanion.insert(
              id: id,
              name: 'Cedar Break Ranch',
              createdBy: 'local',
              createdAt: now,
              updatedAt: now,
            ),
          );
      property = await (db.select(
        db.properties,
      )..where((p) => p.id.equals(id))).getSingle();
    });

    tearDown(() async => db.close());

    /// Drift stream queries close on a zero-length timer after unmount.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
    }

    testWidgets('phone: Settings → About → Diagnostics', (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        host(
          Scaffold(
            body: SettingsTab(db: db, property: property, prefs: prefs),
          ),
        ),
      );
      await settle(tester, 300);
      final row = find.text('DIAGNOSTICS');
      await tester.scrollUntilVisible(row, 300, maxScrolls: 60);
      await tester.pump();
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DiagnosticsScreen), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('desk: Settings → About → Diagnostics', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        host(
          Scaffold(
            body: SettingsWorkspace(db: db, property: property, prefs: prefs),
          ),
        ),
      );
      await settle(tester, 300);
      final row = find.text('Diagnostics');
      await tester.scrollUntilVisible(row, 300, maxScrolls: 60);
      await tester.pump();
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DiagnosticsScreen), findsOneWidget);
      await unmount(tester);
    });
  });
}
