import 'dart:convert';
import 'dart:io';

import 'package:field_notes/screens/backup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixture.dart';

/// The backup screen against a DirectoryTarget under the fixture's temp
/// documents root — the same folder the phone writes, pointed somewhere
/// disposable by the fake path provider.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late WidgetFixture f;

  setUpAll(() async => root = await WidgetFixture.installPlatform());
  setUp(() async {
    f = await WidgetFixture.open();
    await f.seed.record(type: 'plant', taxonId: f.seed.burOakId);
    // A fresh store per test: the screen reads the folder's config.
    final backups = Directory(p.join(root.path, 'backups'));
    if (backups.existsSync()) backups.deleteSync(recursive: true);
  });
  tearDown(() => f.close());

  Future<void> open(WidgetTester tester) async {
    await mount(
      tester,
      height: 1400,
      f.app(BackupScreen(db: f.db, prefs: f.prefs)),
    );
    await settle(tester, 400);
  }

  File manifest() =>
      File(p.join(root.path, 'backups', 'fieldnotes', 'manifest.json'));

  testWidgets('opens unencrypted, never backed up', (tester) async {
    await open(tester);
    expect(find.text('Last backup: never'), findsOneWidget);
    expect(find.text('Last verified: never'), findsOneWidget);
    expect(find.textContaining('Convenience mode'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the encrypt switch flips the mode and its warning',
      (tester) async {
    await open(tester);
    final sw = find.widgetWithText(SwitchListTile, 'Encrypt with a passphrase');
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    await tester.tap(sw);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(sw).value, isTrue);
    expect(find.textContaining('unreadable without your passphrase'),
        findsOneWidget);
    await tester.tap(sw);
    await tester.pump();
    expect(find.textContaining('Convenience mode'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the automatic switch writes the pref', (tester) async {
    await open(tester);
    expect(f.prefs.autoBackup, isTrue);
    final tile = find.widgetWithText(SwitchListTile, 'Back up automatically');
    expect(
      tester.widget<SwitchListTile>(tile).onChanged,
      isNotNull,
      reason: 'the switch is enabled once the config has loaded',
    );
    await tester.tap(tile);
    await tester.pump();
    expect(f.prefs.autoBackup, isFalse);
    await unmount(tester);
  });

  // One test touches BackupService's backup/verify path, deliberately.
  // The service serialises work through a process-wide static future
  // (`_lock`); a second test in the same isolate that chains onto it waits
  // on a continuation queued in the previous test's fake-async zone and
  // never hears back. Not an app bug (one zone there), but it rules out a
  // separate "verify before any backup" case in this file.
  testWidgets('BACK UP NOW writes a manifest; VERIFY BACKUP passes',
      (tester) async {
    await open(tester);
    expect(manifest().existsSync(), isFalse);
    await tester.tap(find.text('BACK UP NOW'));
    await waitFor(tester, find.text('Last backup: just now'));
    expect(manifest().existsSync(), isTrue, reason: 'no manifest written');
    final m = jsonDecode(manifest().readAsStringSync()) as Map;
    expect(m['scheme'], 'plain');
    expect(find.text('Last backup: just now'), findsOneWidget);

    await tester.tap(find.text('VERIFY BACKUP'));
    await waitFor(tester, find.text('Backup verified ✓'));
    expect(find.text('Last verified: just now'), findsOneWidget);
    await unmount(tester);
  });
}
