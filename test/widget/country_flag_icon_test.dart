import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/features/servers/presentation/widgets/country_presentation.dart';

void main() {
  testWidgets(
    'Windows country icon paints a bundled emoji flag without platform fonts',
    (tester) async {
      const boundaryKey = ValueKey('flag-paint');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: CountryFlagIcon(
                  presentation: CountryPresentation.fromName('DE Germany'),
                  width: 80,
                  height: 56,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final flag = tester.widget<Image>(find.byType(Image));
      expect((flag.image as AssetImage).assetName, 'assets/flags/noto/de.png');
      await tester.runAsync(
        () => precacheImage(flag.image, tester.element(find.byType(Image))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Text), findsNothing);
      expect(tester.takeException(), isNull);

      // Actual pixels demonstrate that the image asset was loaded and drawn;
      // merely building an empty async flag widget would not satisfy this test.
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          List<int> pixel(int x, int y) {
            final offset = (y * image.width + x) * 4;
            return [for (var i = 0; i < 4; i++) bytes.getUint8(offset + i)];
          }

          final top = pixel(40, 8);
          expect(top[0], lessThan(65));
          expect(top[1], lessThan(65));
          expect(top[2], lessThan(65));
          expect(top[3], greaterThan(240));
          final middle = pixel(40, 28);
          expect(middle[0], greaterThan(180));
          expect(middle[1], lessThan(50));
          expect(middle[2], lessThan(50));
          final bottom = pixel(40, 48);
          expect(bottom[0], greaterThan(180));
          expect(bottom[1], greaterThan(150));
          expect(bottom[2], lessThan(70));
        } finally {
          image.dispose();
        }
      });
    },
  );

  testWidgets('country icon does not repeat ISO letters in a server row', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final country = CountryPresentation.fromName('🇩🇪 Germany');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Semantics(
              label: country.semanticsLabel,
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    CountryFlagIcon(presentation: country),
                    Text(country.displayName),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Germany'), findsOneWidget);
      expect(find.bySemanticsLabel('de'), findsNothing);
      expect(find.bySemanticsLabel('DE'), findsNothing);
      expect(find.text('Germany'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('unknown country shows a globe and optional accessible label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CountryFlagIcon(
              presentation: CountryPresentation.fromName('My server'),
              semanticsLabel: 'Server location unknown',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.public_rounded), findsOneWidget);
      final data = tester
          .getSemantics(find.bySemanticsLabel('Server location unknown'))
          .getSemanticsData();
      expect(data.flagsCollection.isImage, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
