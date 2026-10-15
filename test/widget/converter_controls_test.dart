import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/converter/presentation/screens/converter_screen.dart';
import 'package:honeyproxyutility/features/converter/presentation/widgets/parsed_result_card.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';

const _link =
    'vless://00000000-0000-4000-8000-000000000000@demo.example.invalid:443?security=tls&type=tcp#Manual%20preview';

void main() {
  testWidgets('Cmd/Ctrl+Enter previews a manual link without saving it', (
    tester,
  ) async {
    final servers = _SavingServers();
    final network = _NoNetwork();
    await _render(tester, servers, network);
    final input = find.byType(TextField);

    for (final modifier in [
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
    ]) {
      final link = _link.replaceFirst(
        '#Manual%20preview',
        modifier == LogicalKeyboardKey.metaLeft
            ? '#Command%20preview'
            : '#Control%20preview',
      );
      await tester.enterText(input, link);
      await tester.pump();
      expect(find.byType(ParsedResultCard), findsNothing);

      await _continueShortcut(tester, modifier);
      await tester.pumpAndSettle();
      final parsed = tester
          .widget<ParsedResultCard>(find.byType(ParsedResultCard))
          .proxy;
      _expectSameProfile(parsed, const LinkDispatcher().dispatch(link));
      expect(servers.requests, isEmpty);
      expect(network.requests, 0);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'pending save ignores repeated taps, locks input, and permits retry after failure',
    (tester) async {
      final servers = _SavingServers();
      final network = _NoNetwork();
      await _render(tester, servers, network);
      final input = find.byType(TextField);
      await tester.enterText(input, _link);
      await tester.pump();
      await _continueShortcut(tester, LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final original = tester
          .widget<ParsedResultCard>(find.byType(ParsedResultCard))
          .proxy;
      final add = find.descendant(
        of: find.byType(ParsedResultCard),
        matching: find.byKey(const ValueKey('import-add-action')),
      );

      // Both events reach the original, still-enabled button before a rebuild.
      // The synchronous saving guard must prevent the second storage request.
      await tester.tap(add);
      await tester.tap(add);
      expect(servers.requests, hasLength(1));
      _expectSameProfile(servers.requests.single, original);
      await tester.pump();
      expect(tester.widget<IconButton>(add).onPressed, isNull);
      expect(tester.widget<TextField>(input).readOnly, isTrue);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('import-preview-action')),
            )
            .onPressed,
        isNull,
      );
      await _continueShortcut(tester, LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(servers.requests, hasLength(1));
      expect(
        tester.widget<ParsedResultCard>(find.byType(ParsedResultCard)).proxy,
        same(original),
      );

      servers.pending.single.completeError(
        StateError('SYNTHETIC_WRITE_FAILURE'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Could not save server'), findsOneWidget);
      expect(find.textContaining('SYNTHETIC_WRITE_FAILURE'), findsNothing);
      expect(tester.widget<IconButton>(add).onPressed, isNotNull);
      expect(tester.widget<TextField>(input).readOnly, isFalse);
      expect(servers.saved, isEmpty);
      expect(
        tester.widget<ParsedResultCard>(find.byType(ParsedResultCard)).proxy,
        same(original),
      );

      await tester.tap(add);
      await tester.pump();
      expect(servers.requests, hasLength(2));
      _expectSameProfile(
        servers.requests.last,
        const LinkDispatcher().dispatch(_link),
      );
      servers.pending.last.complete();
      await tester.pumpAndSettle();
      expect(servers.saved, hasLength(1));
      expect(find.text('Manual preview added'), findsOneWidget);
      expect(tester.widget<TextField>(input).readOnly, isFalse);
      expect(tester.widget<IconButton>(add).onPressed, isNotNull);
      expect(network.requests, 0);
      expect(tester.takeException(), isNull);
      // AppToast owns an auto-dismiss timer; finish it before removing the app.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _render(
  WidgetTester tester,
  _SavingServers servers,
  _NoNetwork network,
) async {
  final dio = Dio()..httpClientAdapter = network;
  addTearDown(() => dio.close(force: true));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stringsProvider.overrideWithValue(const S('en')),
        serversNotifierProvider.overrideWith(() => servers),
        converterDioProvider.overrideWithValue(dio),
      ],
      child: const MaterialApp(home: ConverterScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _continueShortcut(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
) async {
  await tester.sendKeyDownEvent(modifier);
  try {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  } finally {
    await tester.sendKeyUpEvent(modifier);
  }
}

void _expectSameProfile(ParsedProxy actual, ParsedProxy expected) {
  expect(actual.runtimeType, expected.runtimeType);
  expect(actual.host, expected.host);
  expect(actual.port, expected.port);
  expect(actual.name, expected.name);
  expect(actual.protocolLabel, expected.protocolLabel);
}

class _SavingServers extends ServersNotifier {
  final requests = <ParsedProxy>[];
  final pending = <Completer<void>>[];
  final saved = <ParsedProxy>[];

  @override
  Future<List<ServerProfileModel>> build() async => [];

  @override
  Future<void> addFromProxy(
    ParsedProxy proxy, {
    String subscriptionId = '',
  }) async {
    requests.add(proxy);
    final result = Completer<void>();
    pending.add(result);
    await result.future;
    saved.add(proxy);
  }
}

class _NoNetwork implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    throw StateError('Manual link parsing must not make a network request');
  }

  @override
  void close({bool force = false}) {}
}
