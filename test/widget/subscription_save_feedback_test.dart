import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/servers/presentation/screens/servers_screen.dart';
import 'package:honeyproxyutility/features/subscriptions/data/models/subscription_model.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscription_policy.dart';
import 'package:honeyproxyutility/features/subscriptions/presentation/screens/subscriptions_screen.dart';

const _feed = 'https://provider.example.test/feed';
const _draft = 'https://new-provider.example.test/feed';
final _profile = ServerProfileModel(
  id: 7,
  protocol: 'vless',
  name: 'Synthetic server',
  host: '192.0.2.10',
  port: 443,
  configJson: '{}',
  subscriptionId: _feed,
  addedAt: DateTime.utc(2026),
  isSelected: true,
);

void main() {
  for (final locale in ['ru', 'en']) {
    for (final action in [
      'interval',
      'add',
      'server',
      'group',
      'subscription',
    ]) {
      testWidgets(
        '$locale $action storage failure is handled without accepting the mutation',
        (tester) async {
          final fixture = await _render(
            tester,
            locale,
            servers: action == 'server' || action == 'group',
          );
          final strings = S(locale);
          final key = action == 'server'
              ? 'flutter.honeyvpn_servers'
              : 'flutter.nexproxy_subscriptions';
          final store = _MutableFailureStore(
            await SharedPreferencesStorePlatform.instance.getAll(),
            key: key,
            throwing: locale == 'ru',
          );
          SharedPreferencesStorePlatform.instance = store;
          if (action == 'interval') {
            await tester.tap(
              find
                  .byTooltip(
                    locale == 'ru'
                        ? 'Период обновления'
                        : 'Auto-update interval',
                  )
                  .last,
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.text(locale == 'ru' ? 'Каждые 6 ч' : 'Every 6h'),
            );
          } else if (action == 'add') {
            await tester.tap(find.byTooltip(strings.addSubscriptionHint));
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byType(TextField).first,
              'Draft provider',
            );
            await tester.enterText(find.byType(TextField).last, _draft);
            await tester.tap(
              find.widgetWithText(FilledButton, strings.addButton),
            );
          } else {
            if (action == 'server') {
              await tester.tap(find.byKey(const ValueKey('server-actions-7')));
              await tester.pumpAndSettle();
              await tester.tap(find.text(strings.deleteButton));
            } else if (action == 'group') {
              await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
            } else {
              await tester.tap(find.byIcon(Icons.delete_outline).last);
            }
            await tester.pumpAndSettle();
            await tester.tap(
              find.widgetWithText(FilledButton, strings.deleteButton),
            );
          }
          await tester.pumpAndSettle();
          expect(find.text(strings.settingsSaveFailed), findsOneWidget);
          expect(find.textContaining('synthetic-private'), findsNothing);
          expect(tester.takeException(), isNull);
          expect(
            fixture.container.read(serversNotifierProvider).requireValue,
            hasLength(1),
          );
          final subs = fixture.container
              .read(subscriptionsProvider)
              .requireValue
              .subs;
          expect(subs, hasLength(2));
          expect(subs.last.updateIntervalHours, 0);
          expect(subs.last.updateIntervalOverridden, isFalse);
          expect(store.attempts, 2); // Failure plus one same-key restoration.
          if (action == 'add') {
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(
              tester
                  .widget<TextField>(find.byType(TextField).first)
                  .controller!
                  .text,
              'Draft provider',
            );
            expect(
              tester
                  .widget<TextField>(find.byType(TextField).last)
                  .controller!
                  .text,
              _draft,
            );
            expect(fixture.adapter.calls, 0);
            await tester.tap(
              find.widgetWithText(TextButton, strings.cancelButton),
            );
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsNothing);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          fixture.dispose();
        },
      );
    }
  }

  testWidgets(
    'add dialog awaits completion and prevents duplicate submit before closing',
    (tester) async {
      final fixture = await _render(tester, 'en');
      final response = Completer<ResponseBody>();
      fixture.adapter.gate = response;
      await tester.tap(find.byTooltip(const S('en').addSubscriptionHint));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, _draft);
      await tester.tap(
        find.widgetWithText(FilledButton, const S('en').addButton),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byType(AlertDialog), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, const S('en').savingSettings),
      );
      expect(button.onPressed, isNull);
      expect(fixture.adapter.calls, 1);
      response.complete(_feedResponse());
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        fixture.container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .any((sub) => sub.url == _draft),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    },
  );
}

class _IdleConnection extends ConnectionNotifier {
  @override
  NexConnectionState build() => NexConnectionState.initial();
}

class _MutableFailureStore extends InMemorySharedPreferencesStore {
  _MutableFailureStore(
    Map<String, Object> data, {
    required this.key,
    required this.throwing,
  }) : super.withData(data);
  final String key;
  final bool throwing;
  int attempts = 0;
  @override
  Future<bool> setValue(String valueType, String name, Object value) async {
    await super.setValue(valueType, name, value);
    if (name == key) {
      attempts++;
      if (throwing) throw StateError('synthetic-private-storage-detail');
      return false;
    }
    return true;
  }
}

ResponseBody _feedResponse() => ResponseBody.fromString(
  'vless://fixture@192.0.2.20:443?security=none&type=tcp#Synthetic',
  200,
);

class _FeedAdapter implements HttpClientAdapter {
  int calls = 0;
  Completer<ResponseBody>? gate;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return gate == null ? _feedResponse() : gate!.future;
  }

  @override
  void close({bool force = false}) {}
}

class _Fixture {
  _Fixture(this.container, this.adapter, this.dio);
  final ProviderContainer container;
  final _FeedAdapter adapter;
  final Dio dio;
  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
    dio.close(force: true);
  }
}

Future<_Fixture> _render(
  WidgetTester tester,
  String locale, {
  bool servers = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'nexproxy_subscriptions': SubscriptionModel.listToJson(const [
      SubscriptionModel(
        id: 1,
        url: builtInSubscriptionUrl,
        name: 'Free',
        updateIntervalHours: 0,
      ),
      SubscriptionModel(
        id: 2,
        url: _feed,
        name: 'Provider',
        updateIntervalHours: 0,
      ),
    ]),
    'honeyvpn_servers': ServerProfileModel.listToJson([_profile]),
    'honeyvpn_free_server_removed_v1': true,
  });
  final adapter = _FeedAdapter();
  final dio = Dio()..httpClientAdapter = adapter;
  final container = ProviderContainer(
    overrides: [
      stringsProvider.overrideWithValue(S(locale)),
      connectionNotifierProvider.overrideWith(_IdleConnection.new),
      subscriptionDioProvider.overrideWithValue(dio),
    ],
  );
  final fixture = _Fixture(container, adapter, dio);
  addTearDown(fixture.dispose);
  await container.read(subscriptionsProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: servers ? const ServersScreen() : const SubscriptionsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}
