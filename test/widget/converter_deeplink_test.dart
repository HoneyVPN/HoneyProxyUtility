import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/converter/presentation/screens/converter_screen.dart';
import 'package:honeyproxyutility/features/converter/presentation/widgets/parsed_result_card.dart';

void main() {
  testWidgets(
    'a second deep link replaces preview in the same mounted import screen',
    (tester) async {
      const first =
          'vless://00000000-0000-4000-8000-000000000000@example.com:443?security=tls&type=tcp#First';
      const second =
          'vless://00000000-0000-4000-8000-000000000000@example.net:443?security=tls&type=tcp#Second';
      final router = GoRouter(
        initialLocation: '/converter?initialText=${Uri.encodeComponent(first)}',
        routes: [
          GoRoute(
            path: '/converter',
            builder: (_, state) => ConverterScreen(
              initialText: state.uri.queryParameters['initialText'],
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [stringsProvider.overrideWithValue(S('en'))],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      final mountedScreen = tester.state(find.byType(ConverterScreen));
      expect(
        tester
            .widget<ParsedResultCard>(find.byType(ParsedResultCard))
            .proxy
            .name,
        'First',
      );
      router.go('/converter?initialText=${Uri.encodeComponent(second)}');
      // GoRouter applies the new URI asynchronously before scheduling a frame.
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ConverterScreen)), same(mountedScreen));
      expect(
        tester
            .widget<ConverterScreen>(find.byType(ConverterScreen))
            .initialText,
        second,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        second,
      );
      expect(
        tester
            .widget<ParsedResultCard>(find.byType(ParsedResultCard))
            .proxy
            .name,
        'Second',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
