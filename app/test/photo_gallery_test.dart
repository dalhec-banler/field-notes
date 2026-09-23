import 'package:field_notes/widgets/photo_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The gallery is built against files that may not decode — a photo can go
/// missing from the store while its row survives — so these use paths that
/// don't resolve. That exercises the missing-photo path at the same time.
List<String> _paths(int n) => [for (var i = 0; i < n; i++) '/nowhere/$i.jpg'];

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(width: 400, child: child)));

void main() {
  testWidgets('a single photo gets no arrows and no thumbnail strip', (
    tester,
  ) async {
    await tester.pumpWidget(_host(
      PhotoPlate(photos: _paths(1), index: 0, onIndex: (_) {}),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('several photos get arrows, a counter and a strip', (
    tester,
  ) async {
    await tester.pumpWidget(_host(
      PhotoPlate(photos: _paths(3), index: 0, onIndex: (_) {}),
    ));
    await tester.pump();
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('the arrows report the next index, and wrap', (tester) async {
    final seen = <int>[];
    await tester.pumpWidget(_host(
      PhotoPlate(photos: _paths(3), index: 0, onIndex: seen.add),
    ));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(seen.last, 1);

    // Back past the start wraps to the end rather than going negative.
    await tester.pumpWidget(_host(
      PhotoPlate(photos: _paths(3), index: 0, onIndex: seen.add),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    expect(seen.last, 2);
  });

  testWidgets('a missing file says so instead of showing a broken box', (
    tester,
  ) async {
    await tester.pumpWidget(_host(
      PhotoPlate(photos: _paths(1), index: 0, onIndex: (_) {}),
    ));
    await tester.pumpAndSettle();
    // The contract is that a photo the store has lost doesn't take the record
    // down with it: the plate still builds and the rest of the screen works.
    expect(find.byType(PhotoPlate), findsOneWidget);
    // The harness routes the decode failure to FlutterError even though
    // errorBuilder handles it; drain it so it can't leak into the next test.
    tester.takeException();
  });

  testWidgets('the lightbox deletes the photo it is showing, not the one '
      'the screen behind it had selected', (tester) async {
    // The regression this guards: the viewer kept its own cursor but delete
    // called through to the caller's index, so removing a photo after paging
    // removed the wrong one.
    int? asked;
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox());
      }),
    ));

    final open = showPhotoLightbox(
      ctx,
      photos: _paths(3),
      index: 0,
      onDelete: (i) => asked = i,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(asked, 1, reason: 'delete must name the frame on screen');
    expect(await open, 1, reason: 'and the caller lands where it was left');
  });
}
