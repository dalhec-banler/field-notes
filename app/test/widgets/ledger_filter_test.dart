import 'package:field_notes/db/database.dart';
import 'package:field_notes/tabs/ledger_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WidgetFixture f;
  late String oakId;

  setUpAll(WidgetFixture.installPlatform);
  setUp(() async {
    f = await WidgetFixture.open();
    oakId = await f.seed.record(
      type: 'plant',
      taxonId: f.seed.burOakId,
      notes: 'acorns on the ground',
      observedAt: '2026-10-03T12:00:00.000Z',
    );
    await f.seed.record(
      type: 'water',
      notes: 'tank half full',
      removalStatus: 'flagged',
      observedAt: '2026-10-02T12:00:00.000Z',
    );
    await f.seed.record(
      type: 'problem',
      notes: 'fence down',
      accuracy: -1,
      observedAt: '2026-10-01T12:00:00.000Z',
    );
  });
  tearDown(() => f.close());

  final located = <Observation>[];

  Future<void> open(WidgetTester tester) async {
    located.clear();
    await mount(
      tester,
      height: 1200,
      f.app(
        Scaffold(
          body: LedgerTab(
            db: f.db,
            property: f.property,
            prefs: f.prefs,
            onLocate: located.add,
          ),
        ),
      ),
    );
    await settle(tester, 500);
  }

  /// The chip row is a lazy horizontal ListView: a chip past the right
  /// edge is not built until scrolled to, so scroll until it is.
  Future<void> chip(WidgetTester tester, String label) async {
    await tester.dragUntilVisible(
      find.text(label),
      find.byType(ListView).first,
      const Offset(-120, 0),
    );
    await tester.pump();
    await tester.tap(find.text(label));
    await settle(tester, 400);
  }

  /// A row in the picker sheet (the ledger's own rows may carry the same
  /// word, e.g. a water record's type label).
  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byType(ListTile), matching: find.text(label)),
    );
    await settle(tester, 400);
  }

  testWidgets('lists every live record, newest first', (tester) async {
    await open(tester);
    expect(find.text('acorns on the ground'), findsOneWidget);
    expect(find.text('tank half full'), findsOneWidget);
    expect(find.text('fence down'), findsOneWidget);
    final oak = tester.getTopLeft(find.text('acorns on the ground'));
    final fence = tester.getTopLeft(find.text('fence down'));
    expect(oak.dy, lessThan(fence.dy));
    await unmount(tester);
  });

  testWidgets('the type chip narrows the ledger and writes the one filter',
      (tester) async {
    await open(tester);
    await chip(tester, 'TYPE');
    await pick(tester, 'WATER');
    expect(find.text('tank half full'), findsOneWidget);
    expect(find.text('acorns on the ground'), findsNothing);
    expect(find.text('fence down'), findsNothing);
    expect(f.recordFilter.type, 'water');
    expect(f.recordFilter.active, isTrue);

    await chip(tester, '× CLEAR');
    expect(find.text('acorns on the ground'), findsOneWidget);
    expect(f.recordFilter.active, isFalse);
    await unmount(tester);
  });

  testWidgets('the removal chip shows only what is flagged', (tester) async {
    await open(tester);
    await chip(tester, 'REMOVAL');
    expect(find.text('tank half full'), findsOneWidget);
    expect(find.text('acorns on the ground'), findsNothing);
    expect(f.recordFilter.flagged, isTrue);
    await chip(tester, 'REMOVAL');
    expect(find.text('acorns on the ground'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the species chip lists species with records, and narrows',
      (tester) async {
    await open(tester);
    await chip(tester, 'SPECIES');
    expect(find.text('BUR OAK · 1'), findsOneWidget);
    await pick(tester, 'BUR OAK · 1');
    expect(find.text('acorns on the ground'), findsOneWidget);
    expect(find.text('tank half full'), findsNothing);
    expect(f.recordFilter.taxonId, f.seed.burOakId);
    expect(f.recordFilter.taxonLabel, 'Bur Oak');
    await unmount(tester);
  });

  testWidgets('a filter set elsewhere narrows the ledger too', (tester) async {
    await open(tester);
    f.recordFilter.update((r) => r.type = 'problem');
    await settle(tester, 400);
    expect(find.text('fence down'), findsOneWidget);
    expect(find.text('acorns on the ground'), findsNothing);
    await unmount(tester);
  });

  testWidgets('the locate glyph hands the row to the shell; none for no-fix',
      (tester) async {
    await open(tester);
    // Two located rows have a glyph; the no-fix record has none.
    final glyphs = find.byIcon(Icons.location_searching);
    expect(glyphs, findsNWidgets(2));
    await tester.tap(glyphs.first);
    await tester.pump();
    expect(located.map((o) => o.id), [oakId]);
    await unmount(tester);
  });
}
