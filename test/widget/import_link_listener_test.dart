import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:honeyproxyutility/app/import_links/import_link_listener.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/converter/presentation/screens/converter_screen.dart';
import 'package:honeyproxyutility/features/converter/presentation/widgets/parsed_result_card.dart';

const _proxy =
    'vless://00000000-0000-4000-8000-000000000000@example.test:443?security=tls&type=tcp#Preview';
String _link(String source) =>
    'honeyvpn://import?url=${Uri.encodeComponent(source)}';

class _Adapter implements HttpClientAdapter {
  int requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(_proxy, 200);
  }

  @override
  void close({bool force = false}) {}
}

GoRouter _router() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const Scaffold(body: Text('Home')),
    ),
    GoRoute(
      path: '/converter',
      builder: (_, state) => ConverterScreen(
        initialText: state.uri.queryParameters['initialText'],
        importActivation: state.uri.queryParameters['importActivation'],
      ),
    ),
  ],
);

Future<void> _render(
  WidgetTester tester,
  GoRouter router,
  Stream<dynamic> events, {
  Dio? dio,
  String locale = 'en',
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      importLinkEventsProvider.overrideWithValue(events),
      stringsProvider.overrideWithValue(S(locale)),
      if (dio != null) converterDioProvider.overrideWithValue(dio),
    ],
    child: ImportLinkListener(
      router: router,
      child: MaterialApp.router(routerConfig: router),
    ),
  ),
);

void main() {
  testWidgets(
    'cold activation waits for startup then fetches a preview exactly once',
    (tester) async {
      final router = _router();
      final events = StreamController<dynamic>();
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(router.dispose);
      addTearDown(events.close);
      addTearDown(() => dio.close(force: true));
      final raw = _link(
        'https://sub.example.test/private-token?one=a%2Bb&two=c',
      );
      events.add(raw);
      events.add(raw); // Native cold/warm delivery may repeat an activation.
      await _render(tester, router, events.stream, dio: dio);
      await tester.pumpAndSettle();
      expect(find.byType(ConverterScreen), findsOneWidget);
      expect(find.byType(ParsedResultCard), findsOneWidget);
      expect(adapter.requests, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'https://sub.example.test/private-token?one=a%2Bb&two=c',
      );
      expect(find.byKey(const ValueKey('import-add-action')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'running activation replaces preview in the same mounted screen',
    (tester) async {
      final router = _router();
      final events = StreamController<dynamic>();
      addTearDown(router.dispose);
      addTearDown(events.close);
      await _render(tester, router, events.stream);
      events.add(_link(_proxy));
      await tester.pumpAndSettle();
      final mounted = tester.state(find.byType(ConverterScreen));
      final second = _proxy.replaceFirst('#Preview', '#Second');
      events.add(_link(second));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ConverterScreen)), same(mounted));
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

  testWidgets(
    'a new tap of the same source restores preview after manual editing',
    (tester) async {
      final router = _router();
      final events = StreamController<dynamic>();
      addTearDown(router.dispose);
      addTearDown(events.close);
      await _render(tester, router, events.stream);
      final raw = _link(_proxy);
      events.add(raw);
      await tester.pumpAndSettle();
      final mounted = tester.state(find.byType(ConverterScreen));
      final editor = find.byType(TextField);
      await tester.enterText(editor, 'manual draft');
      events.add(raw);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, 'manual draft');
      // The production duplicate clock is monotonic, independent of fake frame time.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2100)),
      );
      events.add(raw);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ConverterScreen)), same(mounted));
      expect(tester.widget<TextField>(editor).controller!.text, _proxy);
      expect(
        tester
            .widget<ParsedResultCard>(find.byType(ParsedResultCard))
            .proxy
            .name,
        'Preview',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final locale in ['ru', 'en']) {
    testWidgets(
      'malformed and transport failures are safely localized in $locale',
      (tester) async {
        final router = _router();
        final events = StreamController<dynamic>();
        addTearDown(router.dispose);
        addTearDown(events.close);
        await _render(tester, router, events.stream, locale: locale);
        events.add(
          'honeyvpn://import?url=https%3A%2F%2Fprivate-marker.example&url=other',
        );
        await tester.pumpAndSettle();
        expect(find.text(S(locale).importLinkInvalid), findsOneWidget);
        expect(find.byType(ConverterScreen), findsNothing);
        expect(find.textContaining('private-marker'), findsNothing);
        events.addError(
          PlatformException(
            code: 'NATIVE_FAILURE',
            message: 'https://private-marker.example',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(S(locale).importLinkUnavailable), findsOneWidget);
        expect(find.textContaining('private-marker'), findsNothing);
        await tester.pump(const Duration(seconds: 4));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('navigation queued at disposal is ignored', (tester) async {
    final router = _router();
    final events = StreamController<dynamic>(sync: true);
    addTearDown(router.dispose);
    addTearDown(events.close);
    await _render(tester, router, events.stream);
    events.add(_link(_proxy));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(tester.takeException(), isNull);
  });
}
