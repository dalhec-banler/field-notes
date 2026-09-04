import 'package:field_notes/theme/theme.dart';
import 'package:field_notes/theme/tokens.dart';
import 'package:field_notes/widgets/press.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pixel-identity contract for the theme seam (D-023 phase 1).
///
/// Baseline goldens are captured on the code as it stood BEFORE the tokens
/// became switchable. After the sweep, the same composite must render
/// byte-for-byte the same in the press skin. If this test fails, the seam
/// changed the design, which phase 1 is not allowed to do.
///
/// Regenerate deliberately (design change, new widget added here) with:
///   flutter test --update-goldens test/skin_golden_test.dart
void main() {
  setUp(() => skin = pressSkin);
  tearDown(() => skin = quietSkin);

  Widget composite() => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    home: Scaffold(
      body: ListView(
        padding: EdgeInsets.all(Metrics.gutter),
        children: [
          ScreenHeader(
            kicker: 'Configuration · This Device',
            title: 'SETTINGS',
          ),
          SizedBox(height: 10),
          Kicker('Field Journal'),
          MonoLabel(
            'ON THIS PHONE · WORKS WITH NO SIGNAL',
            size: 9,
            spacing: 1.8,
          ),
          SizedBox(height: 10),
          InkCard(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TaxonName('Quercus macrocarpa'),
                  FactRow('zone', 'North Pasture'),
                  FactRow('rain, 30 d', '41.2 mm · 9 d since rain'),
                ],
              ),
            ),
          ),
          SizedBox(height: 10),
          StatusPill('alive', color: Press.sage),
          SizedBox(height: 10),
          BigNumber('78', unit: '%'),
          const SizedBox(height: 10),
          StatCells(
            cells: const [('PLANTED', '40', null), ('ALIVE', '31', null)],
          ),
          const SizedBox(height: 10),
          RailNote(
            color: Press.sage,
            label: 'Mechanism',
            body:
                'Identity is the tag. The plant does not move; '
                'the tag does not lie.',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton(onPressed: () {}, child: const Text('BACK UP NOW')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () {}, child: const Text('RESTORE')),
            ],
          ),
        ],
      ),
      floatingActionButton: CaptureFab(onPressed: () {}),
    ),
  );

  testWidgets('quiet skin composite (reference render)', (tester) async {
    skin = quietSkin;
    await tester.binding.setSurfaceSize(const Size(430, 900));
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(composite());
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/quiet_composite.png'),
    );
  });

  testWidgets('press skin renders exactly as the baseline', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(composite());
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/press_composite.png'),
    );
  });
}

// The quiet composite is a reference render, not a regression contract yet —
// it exists so a change to the quiet skin is a visible, reviewed diff.
