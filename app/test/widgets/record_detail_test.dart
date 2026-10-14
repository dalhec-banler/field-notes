import 'package:field_notes/screens/record_detail_screen.dart';
import 'package:field_notes/services/observation_ops.dart';
import 'package:field_notes/widgets/save_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WidgetFixture f;
  late String obsId;

  setUpAll(WidgetFixture.installPlatform);
  setUp(() async {
    f = await WidgetFixture.open();
    obsId = await f.seed.record(
      type: 'plant',
      taxonId: f.seed.burOakId,
      zoneId: f.seed.northZoneId,
      notes: 'leafing out early',
    );
    await f.seed.record(type: 'water', j: 0.0001, notes: 'spring running');
  });
  tearDown(() => f.close());

  Future<void> open(WidgetTester tester) async {
    await mount(
      tester,
      f.host<void>(() => RecordDetailScreen(db: f.db, obsId: obsId), (_) {}),
    );
    await settle(tester);
    await tester.tap(find.text('OPEN'));
    await settle(tester, 500);
  }

  testWidgets('renders the record: name, facts, notes, what is nearby',
      (tester) async {
    await open(tester);
    expect(find.byType(RecordDetailScreen), findsOneWidget);
    expect(find.text('Quercus macrocarpa'), findsOneWidget);
    expect(find.textContaining('BUR OAK'), findsOneWidget);
    expect(find.text('leafing out early'), findsOneWidget);
    expect(find.text('North Pasture'), findsOneWidget);
    expect(find.textContaining('30.88300, -98.54700'), findsOneWidget);
    // The water record ~15 m away shows under Nearby.
    expect(find.textContaining('spring running'), findsOneWidget);
    expect(find.text('EDIT'), findsOneWidget);
    expect(find.text('DELETE'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('EDIT changes the notes through applyRecordEdit', (tester) async {
    await open(tester);
    await tester.tap(find.text('EDIT'));
    await tester.pumpAndSettle();
    final notes = find.widgetWithText(TextField, 'leafing out early');
    expect(notes, findsOneWidget);
    await tester.enterText(notes, 'leafing out, bagworms on the north side');
    // Let the field go before the sheet does: the sheet disposes its
    // controller the moment it pops, and a focus change during the exit
    // slide would rebuild the field against the disposed controller.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(find.text('SAVE CHANGES'));
    await settle(tester, 500);
    final row = await f.observations.single(obsId);
    expect(row.notes, 'leafing out, bagworms on the north side');
    expect(row.taxonId, f.seed.burOakId);
    expect(find.text('leafing out, bagworms on the north side'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('DELETE soft-deletes and leaves the screen', (tester) async {
    await open(tester);
    await tester.tap(find.text('DELETE'));
    await tester.pumpAndSettle();
    expect(find.text('DELETE RECORD?'), findsOneWidget);
    await tester.tap(find.text('DELETE').last);
    await settle(tester, 500);
    expect(find.byType(RecordDetailScreen), findsNothing);
    final row = await f.observations.single(obsId);
    expect(row.deletedAt, isNotNull);
    // The photos (none here) would stay; the row is a tombstone, not gone.
    await unmount(tester);
  });

  testWidgets('FLAG FOR REMOVAL marks the record and the chip appears',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('FLAG FOR REMOVAL'));
    await settle(tester, 500);
    expect((await f.observations.single(obsId)).removalStatus, 'flagged');
    expect(find.text('MARK REMOVED'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('UNDO on the save toast erases a never-pushed record',
      (tester) async {
    // The toast is the shell's; the write it undoes is the repo's.
    late BuildContext ctx;
    await mount(
      tester,
      f.app(
        Builder(
          builder: (context) {
            ctx = context;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
    await tester.pump();
    UndoOutcome? outcome;
    SaveToast.show(
      ctx,
      title: 'OBSERVATION WRITTEN',
      detail: 'SAVED ON THIS PHONE',
      onUndo: () async {
        outcome = await f.observations.undo(obsId, log: null);
      },
    );
    await tester.pump();
    expect(find.text('UNDO'), findsOneWidget);
    await tester.tap(find.text('UNDO'));
    await settle(tester, 400);
    expect(outcome, UndoOutcome.erased);
    expect(await f.observations.byId(obsId), isNull);
    SaveToast.dismiss();
    await unmount(tester);
  });
}
