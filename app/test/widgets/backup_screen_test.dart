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

  testWidgets('the encrypt switch flips the mode and its warning', (
    tester,
  ) async {
    await open(tester);
    final sw = find.widgetWithText(SwitchListTile, 'Encrypt with a passphrase');
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    await tester.tap(sw);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(sw).value, isTrue);
    expect(
      find.textContaining('unreadable without your passphrase'),
      findsOneWidget,
    );
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

  // Three tests touch BackupService's backup/verify path in one isolate.
  // That used to be impossible: the service serialised through a chained
  // static Future, and a continuation created in one test's fake-async
  // zone never resumed in the next. The gate is a busy flag plus a waiter
  // queue now, so these run back to back — which is itself the regression
  // test for that lock.
  testWidgets('VERIFY before any backup says so, and does not hang', (
    tester,
  ) async {
    await open(tester);
    expect(manifest().existsSync(), isFalse);
    await tester.tap(find.text('VERIFY BACKUP'));
    // With no store yet, verify reports a problem (or "run a backup first");
    // what matters here is that it answers at all.
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data ?? '').isNotEmpty &&
            ((w.data!).startsWith('Problem:') ||
                w.data == 'Run a backup first.'),
      ),
    );
    expect(manifest().existsSync(), isFalse);
    await unmount(tester);
  });

  testWidgets('BACK UP NOW writes a manifest; VERIFY BACKUP passes', (
    tester,
  ) async {
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

  testWidgets('a second BACK UP NOW in the same process also completes', (
    tester,
  ) async {
    await open(tester);
    expect(manifest().existsSync(), isFalse);
    await tester.tap(find.text('BACK UP NOW'));
    // The config file lives beside the store, not in it, so the previous
    // test's timestamp can already read "just now" here; the manifest is
    // the thing this press has to produce.
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (!manifest().existsSync()) {
      if (DateTime.now().isAfter(until)) fail('second backup never wrote');
      await settle(tester, 200);
    }
    await unmount(tester);
  });
}
