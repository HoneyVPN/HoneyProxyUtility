import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/marketplace/presentation/screens/provider_detail_screen.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscription_policy.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';

const _buttonKey = ValueKey('add-built-in-free-server');

ServerProfileModel _freeProfile() => ServerProfileModel(
  id: 1,
  protocol: 'vless',
  name: 'Free server',
  host: 'example.invalid',
  port: 443,
  configJson: '{}',
  subscriptionId: builtInSubscriptionUrl,
  addedAt: DateTime(2026),
);

void main() {
  for (final locale in ['ru', 'en']) {
    testWidgets('existing free server disables catalog add in $locale', (
      tester,
    ) async {
      final subscriptions = _Subscriptions();
      final servers = _Servers([_freeProfile()]);
      await _render(tester, servers, subscriptions, locale: locale);

      expect(
        tester.widget<TextButton>(find.byKey(_buttonKey)).onPressed,
        isNull,
      );
      expect(
        find.text(locale == 'ru' ? 'Сервер добавлен' : 'Server added'),
        findsOneWidget,
      );
      expect(find.textContaining(builtInSubscriptionUrl), findsNothing);
      expect(find.text('Добавить серверы'), findsNothing);
      expect(find.text('Add servers'), findsNothing);
      expect(subscriptions.addCalls, 0);
      expect(
        find.text(locale == 'ru' ? '90₽ / 30 дней' : '90 RUB / 30 days'),
        findsOneWidget,
      );
      expect(
        find.text(locale == 'ru' ? '3 дня бесплатно' : '3 days free'),
        findsOneWidget,
      );
      await tester.tap(
        find.text(locale == 'ru' ? 'Подробнее о сервисе' : 'Provider details'),
      );
      await tester.pumpAndSettle();
      for (final feature
          in locale == 'ru'
              ? [
                  'Лучший VPN сервис',
                  'Hysteria2 протокол',
                  'VLESS протокол',
                  'Все сервисы работают',
                  'Быстрые серверы',
                ]
              : [
                  'The best VPN service',
                  'Hysteria2 protocol',
                  'VLESS protocol',
                  'All services work',
                  'Fast servers',
                ]) {
        expect(find.text(feature), findsOneWidget);
      }
      if (locale == 'en') {
        expect(find.text('90₽ / 30 дней'), findsNothing);
        expect(find.text('3 дня бесплатно'), findsNothing);
        expect(find.text('Лучший VPN сервис'), findsNothing);
      }

      // A user removal immediately makes the explicit restore action available.
      servers.show([]);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextButton>(find.byKey(_buttonKey)).onPressed,
        isNotNull,
      );
      expect(
        find.text(locale == 'ru' ? 'Добавить сервер' : 'Add server'),
        findsOneWidget,
      );
    });
  }

  testWidgets('add is single-flight and keeps paid Telegram action', (
    tester,
  ) async {
    final pending = Completer<void>();
    final subscriptions = _Subscriptions(onAdd: () => pending.future);
    final servers = _Servers([]);
    String? externalUrl;
    await _render(
      tester,
      servers,
      subscriptions,
      onOpenExternal: (url) => externalUrl = url,
    );

    // Both taps arrive before the next frame; only one request may begin.
    await tester.tap(find.byKey(_buttonKey));
    await tester.tap(find.byKey(_buttonKey));
    await tester.pump();
    expect(subscriptions.addCalls, 1);
    expect(tester.widget<TextButton>(find.byKey(_buttonKey)).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.text('Открыть в Telegram'));
    expect(externalUrl, 'https://t.me/honeyvpnru_bot');

    servers.show([_freeProfile()]);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Сервер добавлен'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(_buttonKey)).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed add presents a short error and permits retry', (
    tester,
  ) async {
    final subscriptions = _Subscriptions(
      onAdd: () => Future<void>.error(
        StateError('private transport details must not reach the UI'),
      ),
    );
    await _render(tester, _Servers([]), subscriptions);
    await tester.tap(find.byKey(_buttonKey));
    await tester.pumpAndSettle();

    expect(find.text('Не удалось добавить сервер'), findsOneWidget);
    expect(find.textContaining('private transport details'), findsNothing);
    expect(
      tester.widget<TextButton>(find.byKey(_buttonKey)).onPressed,
      isNotNull,
    );
    expect(subscriptions.addCalls, 1);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _render(
  WidgetTester tester,
  _Servers servers,
  _Subscriptions subscriptions, {
  String locale = 'ru',
  ValueChanged<String>? onOpenExternal,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stringsProvider.overrideWithValue(S(locale)),
        serversNotifierProvider.overrideWith(() => servers),
        subscriptionsProvider.overrideWith(() => subscriptions),
      ],
      child: MaterialApp(
        theme: honeyThemeLight,
        home: ProviderDetailScreen(
          id: 'honeyvpn',
          onOpenExternal: onOpenExternal,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Servers extends ServersNotifier {
  _Servers(this.initial);

  final List<ServerProfileModel> initial;

  @override
  Future<List<ServerProfileModel>> build() async => initial;

  void show(List<ServerProfileModel> profiles) => state = AsyncData(profiles);
}

class _Subscriptions extends SubscriptionsNotifier {
  _Subscriptions({this.onAdd});

  final Future<void> Function()? onAdd;
  int addCalls = 0;

  @override
  Future<SubscriptionsState> build() async => const SubscriptionsState();

  @override
  Future<void> addBuiltInFreeServer() async {
    addCalls++;
    await onAdd?.call();
  }
}
