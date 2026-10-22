import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../../lib/features/converter/data/parsers/link_dispatcher.dart';
import '../../../lib/features/connection/data/datasources/singbox_datasource.dart';
import '../../../lib/features/connection/domain/entities/connection_state.dart';
import '../../../lib/features/connection/domain/entities/vpn_core_status.dart';
import '../../../lib/features/connection/presentation/notifiers/connection_notifier.dart';
import '../../../lib/features/servers/data/models/server_profile_model.dart';
import '../../../lib/features/servers/presentation/notifiers/servers_notifier.dart';
import '../../../lib/features/subscriptions/data/models/subscription_model.dart';
import '../../../lib/features/subscriptions/data/services/subscription_policy.dart';
import '../../../lib/features/subscriptions/data/services/subscriptions_notifier.dart';

const _freeBody =
    'vless://first@first.example.test:443?security=tls#First\n'
    'vless://second@second.example.test:443?security=tls#Second\n'
    'vless://third@third.example.test:443?security=tls#Third';
const _custom = 'https://custom.example.test/feed';
const _removedKey = 'honeyvpn_free_server_removed_v1';
const _freeAliases = [
  'HTTPS://SUB.HONEYVPN.RU:443/5BQLnwsNJ5nvF6dH#choice',
  'https://sub.honeyvpn.ru/5BQLnwsNJ5nvF6dH?',
  'https://sub.honeyvpn.ru/5BQLnwsNJ5nvF6dH#another',
];

class _DrawRandom implements Random {
  _DrawRandom(this.draws);
  final List<int> draws;
  var index = 0;

  @override
  int nextInt(int max) => draws[(index++) % draws.length] % max;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  final calls = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    calls.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

class _ConnectedSource extends VpnDatasource {
  _ConnectedSource()
    : super(onStatusChanged: (_) {}, platform: VpnPlatform.unsupported);
  var stops = 0;
  var reattachments = 0;
  var disposed = false;

  @override
  bool get requiresNativeSessionDiscovery => false;

  @override
  Future<VpnCoreStatus?> readCurrentStatus() async =>
      const VpnCoreStatus(state: 'CONNECTED');

  @override
  void reattach() => reattachments++;

  @override
  Future<void> stop() async => stops++;

  @override
  void dispose() => disposed = true;
}

class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore(super.data) : super.withData();
  String? failKey;
  Object? failValue;
  bool throwFailure = false;
  final writes = <String>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(key);
    // Match Windows' backend cache mutation before returning a disk failure.
    await super.setValue(valueType, key, value);
    if (key == failKey && (failValue == null || value == failValue)) {
      if (throwFailure) throw StateError('Synthetic preference failure');
      return false;
    }
    return true;
  }
}

Future<_FailingStore> _failingStore(String key, {Object? value}) async {
  final store =
      _FailingStore(await SharedPreferencesStorePlatform.instance.getAll())
        ..failKey = 'flutter.$key'
        ..failValue = value;
  SharedPreferencesStorePlatform.instance = store;
  return store;
}

ResponseBody _response(String text) => ResponseBody.fromString(text, 200);

class _Fixture {
  _Fixture(this.container, this.adapter, this.dio);
  final ProviderContainer container;
  final _Adapter adapter;
  final Dio dio;

  SubscriptionsNotifier get subs =>
      container.read(subscriptionsProvider.notifier);
  ServersNotifier get servers =>
      container.read(serversNotifierProvider.notifier);
  List<ServerProfileModel> get free => container
      .read(serversNotifierProvider)
      .requireValue
      .where((s) => s.subscriptionId == builtInSubscriptionUrl)
      .toList();
  SubscriptionModel get freeSub => container
      .read(subscriptionsProvider)
      .requireValue
      .subs
      .singleWhere((s) => s.url == builtInSubscriptionUrl);

  var _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
    dio.close(force: true);
  }
}

Future<void> _finishRefresh(WidgetTester tester, _Fixture fixture) async {
  final wait = Stopwatch()..start();
  while (fixture.container
      .read(subscriptionsProvider)
      .requireValue
      .refreshing
      .isNotEmpty) {
    if (wait.elapsed > const Duration(seconds: 10)) {
      fail('Automatic subscription refresh did not complete');
    }
    // Keep the automatic cadence under the fake clock, but allow the real
    // parsing isolate to reply before asserting the automatic refresh result.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump();
  }
}

Future<_Fixture> _fixture({
  Map<String, Object>? storage = const {},
  List<int> draws = const [0],
  Future<ResponseBody> Function(RequestOptions)? respond,
  bool drainStartup = true,
  VpnDatasourceFactory? sourceFactory,
}) async {
  if (storage != null) SharedPreferences.setMockInitialValues(storage);
  final adapter = _Adapter(respond ?? (_) async => _response(_freeBody));
  final dio = Dio()..httpClientAdapter = adapter;
  final container = ProviderContainer(
    overrides: [
      subscriptionDioProvider.overrideWithValue(dio),
      builtInFreeRandomProvider.overrideWithValue(_DrawRandom(draws)),
      if (sourceFactory != null)
        vpnDatasourceFactoryProvider.overrideWithValue(sourceFactory),
    ],
  );
  final fixture = _Fixture(container, adapter, dio);
  addTearDown(fixture.dispose);
  await container.read(subscriptionsProvider.future);
  if (drainStartup) {
    await fixture.subs.refresh(fixture.freeSub.id);
    await Future<void>.delayed(Duration.zero);
  }
  return fixture;
}

ServerProfileModel _stored(int id, String source, {bool selected = false}) =>
    ServerProfileModel(
      id: id,
      protocol: 'vless',
      name: 'Stored $id',
      host: 'stored-$id.example.test',
      port: 443,
      configJson: jsonEncode({
        'rawLink': 'vless://$id@stored-$id.example.test:443?security=tls',
      }),
      subscriptionId: source,
      addedAt: DateTime(2025),
      isSelected: selected,
      isFavorite: selected,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup and overlapping imports store only one free profile', () async {
    final fixture = await _fixture();
    final proxies = const LinkDispatcher().dispatchMultiple(_freeBody);
    await Future.wait([
      fixture.subs.refreshAll(),
      fixture.subs.refresh(fixture.freeSub.id),
      fixture.subs.importProxies(builtInSubscriptionUrl, proxies),
      fixture.servers.addFromProxies(
        proxies,
        subscriptionId: ' $builtInSubscriptionUrl\x00 ',
      ),
    ]);
    expect(fixture.free, hasLength(1));
    final prefs = await SharedPreferences.getInstance();
    expect(
      ServerProfileModel.listFromJson(
        prefs.getString('honeyvpn_servers')!,
      ).where((s) => s.subscriptionId == builtInSubscriptionUrl),
      hasLength(1),
    );
  });

  test(
    'equivalent built-in HTTPS aliases use the same one-node limit and opt-out',
    () async {
      final fixture = await _fixture();
      final proxies = const LinkDispatcher().dispatchMultiple(_freeBody);
      for (final alias in _freeAliases) {
        expect(
          normalizeSubscriptionUrl(' $alias\x00 '),
          builtInSubscriptionUrl,
        );
        await fixture.subs.importProxies(alias, proxies);
        expect(fixture.free, hasLength(1));
        expect(
          fixture.container.read(serversNotifierProvider).requireValue,
          hasLength(1),
        );
        expect(
          fixture.container.read(subscriptionsProvider).requireValue.subs,
          hasLength(1),
        );
      }
      await fixture.servers.delete(
        fixture.free.single.id,
        expectedSubscriptionId: _freeAliases.first,
      );
      for (final alias in _freeAliases) {
        expect(await fixture.subs.importProxies(alias, proxies), 0);
        await fixture.servers.addFromProxies(proxies, subscriptionId: alias);
      }
      expect(fixture.free, isEmpty);
      expect((await fixture.servers.freeServerSnapshot()).removed, isTrue);
    },
  );

  test(
    'non-equivalent paid/custom URL strings retain their exact semantics',
    () {
      const different = [
        'http://sub.honeyvpn.ru/5BQLnwsNJ5nvF6dH',
        'https://user@sub.honeyvpn.ru/5BQLnwsNJ5nvF6dH',
        'https://@sub.honeyvpn.ru/5BQLnwsNJ5nvF6dH',
        'https://sub.honeyvpn.ru:444/5BQLnwsNJ5nvF6dH',
        'https://sub.honeyvpn.ru/5BQLnwsNJ5nvF6dH/',
        'https://sub.honeyvpn.ru/5BQLnwsNJ5nvF6dH?token=fake',
        'HTTPS://CUSTOM.EXAMPLE.TEST:443/feed#custom',
      ];
      for (final url in different) {
        expect(normalizeSubscriptionUrl(' $url\x00 '), url);
        expect(
          subscriptionProxies(
            url,
            const LinkDispatcher().dispatchMultiple(_freeBody),
          ),
          hasLength(3),
        );
      }
    },
  );

  test(
    'old saved aliases are repaired offline as the same free subscription',
    () async {
      final fixture = await _fixture(
        storage: {
          'honeyvpn_servers': ServerProfileModel.listToJson([
            _stored(1, builtInSubscriptionUrl),
            _stored(2, _freeAliases.first, selected: true),
            _stored(3, _custom),
          ]),
          'nexproxy_subscriptions': SubscriptionModel.listToJson([
            SubscriptionModel(
              id: 1,
              url: _freeAliases.first,
              name: 'HoneyVPN',
              lastUpdated: DateTime(2025),
              updateIntervalHours: 24,
            ),
            const SubscriptionModel(
              id: 2,
              url: builtInSubscriptionUrl,
              name: 'Duplicate',
            ),
          ]),
        },
        respond: (_) async => _response(''),
      );
      expect(fixture.free, hasLength(1));
      expect(fixture.free.single.id, 2);
      expect(
        fixture.container.read(subscriptionsProvider).requireValue.subs,
        hasLength(1),
      );
      expect(
        fixture.container
            .read(serversNotifierProvider)
            .requireValue
            .where((s) => s.subscriptionId == _custom),
        hasLength(1),
      );
    },
  );

  test(
    'refresh draws again despite selected/favorite; same draw is allowed',
    () async {
      final fixture = await _fixture(draws: [0, 1, 1]);
      final first = fixture.free.single;
      await fixture.servers.selectServer(first);
      await fixture.subs.refresh(fixture.freeSub.id);
      final second = fixture.free.single;
      expect(second.host, 'second.example.test');
      expect(second.id, isNot(first.id));
      expect(second.isSelected, isTrue);
      await fixture.subs.refresh(fixture.freeSub.id);
      expect(fixture.free.single.host, second.host);
      expect(fixture.free.single.id, second.id);
      expect(fixture.free, hasLength(1));
    },
  );

  test(
    'free rotation leaves an already connected tunnel and active profile intact',
    () async {
      final source = _ConnectedSource();
      var sourceCreations = 0;
      final fixture = await _fixture(
        draws: [0, 1],
        sourceFactory:
            ({
              required void Function(VpnCoreStatus) onStatusChanged,
              void Function(String)? onError,
            }) {
              sourceCreations++;
              return source;
            },
      );
      await fixture.servers.selectServer(fixture.free.single);
      fixture.container.read(connectionNotifierProvider);
      await Future<void>.delayed(Duration.zero);
      final old = fixture.container.read(connectionNotifierProvider);
      expect(old.status, ConnectionStatus.connected);
      expect(old.activeServer!.host, 'first.example.test');
      await fixture.subs.refresh(fixture.freeSub.id);
      final current = fixture.container.read(connectionNotifierProvider);
      expect(fixture.free.single.host, 'second.example.test');
      expect(current.status, ConnectionStatus.connected);
      expect(identical(current.activeServer, old.activeServer), isTrue);
      expect(current.activeServer!.configJson, old.activeServer!.configJson);
      expect(source.stops, 0);
      expect(source.disposed, isFalse);
      expect(source.reattachments, 1);
      expect(sourceCreations, 1);
    },
  );

  testWidgets(
    'automatic refresh retries and rotates; removed free feed stays absent',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'honeyvpn_servers': ServerProfileModel.listToJson([
          _stored(10, builtInSubscriptionUrl, selected: true),
        ]),
      });
      var body = '';
      final adapter = _Adapter((_) async => _response(body));
      final dio = Dio()..httpClientAdapter = adapter;
      final container = ProviderContainer(
        overrides: [
          subscriptionDioProvider.overrideWithValue(dio),
          builtInFreeRandomProvider.overrideWithValue(_DrawRandom([1])),
        ],
      );
      final fixture = _Fixture(container, adapter, dio);
      addTearDown(fixture.dispose);
      await container.read(subscriptionsProvider.future);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      await _finishRefresh(tester, fixture);
      expect(fixture.free.single.host, 'stored-10.example.test');
      expect(fixture.freeSub.lastUpdated, isNull);
      body = _freeBody;
      await tester.pump(const Duration(minutes: 1));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      await _finishRefresh(tester, fixture);
      expect(fixture.free.single.host, 'second.example.test');
      expect(fixture.freeSub.lastUpdated, isNotNull);
      await fixture.servers.delete(fixture.free.single.id);
      final calls = adapter.calls.length;
      await tester.pump(const Duration(minutes: 2));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(fixture.free, isEmpty);
      expect(adapter.calls, hasLength(calls));
      fixture.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'an overdue removed free feed is skipped on every automatic tick',
    (tester) async {
      final fixture = await _fixture(
        drainStartup: false,
        storage: {
          _removedKey: true,
          'nexproxy_subscriptions': SubscriptionModel.listToJson([
            SubscriptionModel(
              id: 1,
              url: builtInSubscriptionUrl,
              name: 'HoneyVPN',
              lastUpdated: DateTime(2025),
              updateIntervalHours: 1,
            ),
          ]),
        },
      );
      expect(fixture.freeSub.needsRefresh, isTrue);
      await tester.pump();
      await tester.pump(const Duration(minutes: 3));
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(fixture.free, isEmpty);
      expect(fixture.adapter.calls, isEmpty);
      expect(
        fixture.container.read(subscriptionsProvider).requireValue.refreshing,
        isEmpty,
      );
      fixture.dispose();
      await tester.pump();
    },
  );

  test('delete opts out across refresh, import and restart', () async {
    final fixture = await _fixture();
    await fixture.servers.delete(fixture.free.single.id);
    final calls = fixture.adapter.calls.length;
    await fixture.subs.refreshAll();
    await fixture.subs.importProxies(
      builtInSubscriptionUrl,
      const LinkDispatcher().dispatchMultiple(_freeBody),
    );
    await fixture.servers.addFromProxies(
      const LinkDispatcher().dispatchMultiple(_freeBody),
      subscriptionId: builtInSubscriptionUrl,
    );
    expect(fixture.free, isEmpty);
    expect(fixture.adapter.calls, hasLength(calls));
    expect(
      (await SharedPreferences.getInstance()).getBool(_removedKey),
      isTrue,
    );
    fixture.dispose();
    final restarted = await _fixture(storage: null);
    expect(restarted.free, isEmpty);
    expect(restarted.adapter.calls, isEmpty);
  });

  test(
    'free delete confirmation still applies after refresh rotates its id',
    () async {
      final fixture = await _fixture(draws: [0, 1]);
      final captured = fixture.free.single;
      await fixture.subs.refresh(fixture.freeSub.id);
      expect(fixture.free.single.id, isNot(captured.id));
      await fixture.servers.delete(
        captured.id,
        expectedSubscriptionId: captured.subscriptionId,
      );
      await fixture.subs.refreshAll();
      expect(fixture.free, isEmpty);
      expect((await fixture.servers.freeServerSnapshot()).removed, isTrue);
    },
  );

  test('free bulk deletion carries captured source across rotation', () async {
    final fixture = await _fixture(draws: [0, 1]);
    final captured = fixture.free.single;
    await fixture.subs.refresh(fixture.freeSub.id);
    await fixture.servers.deleteAll([
      captured.id,
    ], expectedSubscriptionId: captured.subscriptionId);
    expect(fixture.free, isEmpty);
    expect((await fixture.servers.freeServerSnapshot()).removed, isTrue);
  });

  test('a stale free id cannot delete a reused paid id', () async {
    final fixture = await _fixture(
      storage: {
        'honeyvpn_servers': ServerProfileModel.listToJson([
          _stored(11, builtInSubscriptionUrl),
          _stored(10, _custom),
        ]),
        'nexproxy_subscriptions': SubscriptionModel.listToJson([
          SubscriptionModel(
            id: 1,
            url: builtInSubscriptionUrl,
            name: 'HoneyVPN',
            lastUpdated: DateTime.now(),
            updateIntervalHours: 24,
          ),
        ]),
      },
      drainStartup: false,
    );
    final captured = fixture.free.single;
    await fixture.servers.delete(captured.id);
    await fixture.subs.importProxies(
      _custom,
      const LinkDispatcher().dispatchMultiple(_freeBody),
    );
    expect(
      fixture.container
          .read(serversNotifierProvider)
          .requireValue
          .any((s) => s.id == captured.id && s.subscriptionId == _custom),
      isTrue,
    );
    await fixture.servers.delete(
      captured.id,
      expectedSubscriptionId: captured.subscriptionId,
    );
    expect(
      fixture.container
          .read(serversNotifierProvider)
          .requireValue
          .where((s) => s.subscriptionId == _custom),
      hasLength(3),
    );
  });

  test(
    'subscription deletion cannot remove metadata if saving opt-out fails',
    () async {
      final fixture = await _fixture();
      final sub = fixture.freeSub;
      final store = await _failingStore(_removedKey, value: true);
      await expectLater(fixture.subs.delete(sub.id), throwsStateError);
      final persisted = await store.getAll();
      expect(persisted['flutter.$_removedKey'], isFalse);
      expect(
        SubscriptionModel.listFromJson(
          persisted['flutter.nexproxy_subscriptions']! as String,
        ).any((s) => s.url == builtInSubscriptionUrl),
        isTrue,
      );
      expect(store.writes, ['flutter.$_removedKey', 'flutter.$_removedKey']);
      expect(fixture.free, hasLength(1));
    },
  );

  test(
    'failed profile deletion retains durable opt-out and metadata',
    () async {
      final fixture = await _fixture();
      final sub = fixture.freeSub;
      final store = await _failingStore('honeyvpn_servers');
      await expectLater(fixture.subs.delete(sub.id), throwsStateError);
      final persisted = await store.getAll();
      expect(persisted['flutter.$_removedKey'], isTrue);
      expect(
        SubscriptionModel.listFromJson(
          persisted['flutter.nexproxy_subscriptions']! as String,
        ).any((s) => s.url == builtInSubscriptionUrl),
        isTrue,
      );
      expect(store.writes, [
        'flutter.$_removedKey',
        'flutter.honeyvpn_servers',
        'flutter.honeyvpn_servers',
      ]);
      fixture.dispose();
      final restarted = await _fixture(storage: persisted);
      expect(restarted.free, isEmpty);
      expect(restarted.adapter.calls, isEmpty);
    },
  );

  test(
    'metadata deletion failure follows persisted opt-out and profile deletion',
    () async {
      final fixture = await _fixture();
      final sub = fixture.freeSub;
      final store = await _failingStore('nexproxy_subscriptions');
      await expectLater(fixture.subs.delete(sub.id), throwsStateError);
      final persisted = await store.getAll();
      expect(persisted['flutter.$_removedKey'], isTrue);
      expect(
        ServerProfileModel.listFromJson(
          persisted['flutter.honeyvpn_servers']! as String,
        ),
        isEmpty,
      );
      expect(store.writes, [
        'flutter.$_removedKey',
        'flutter.honeyvpn_servers',
        'flutter.nexproxy_subscriptions',
        'flutter.nexproxy_subscriptions',
      ]);
      fixture.dispose();
      final restarted = await _fixture(storage: persisted);
      expect(restarted.free, isEmpty);
      expect(restarted.adapter.calls, isEmpty);
    },
  );

  test('failed explicit restore preference does not clear opt-out', () async {
    final fixture = await _fixture();
    await fixture.servers.delete(fixture.free.single.id);
    final store = await _failingStore(_removedKey, value: false);
    await expectLater(fixture.subs.addBuiltInFreeServer(), throwsStateError);
    final persisted = await store.getAll();
    expect(persisted['flutter.$_removedKey'], isTrue);
    expect(
      ServerProfileModel.listFromJson(
        persisted['flutter.honeyvpn_servers']! as String,
      ),
      hasLength(1),
    );
    expect(fixture.free, isEmpty);
    fixture.dispose();
    final restarted = await _fixture(storage: persisted);
    expect(restarted.free, isEmpty);
    expect(restarted.adapter.calls, isEmpty);
    await restarted.subs.addBuiltInFreeServer();
    expect(restarted.free, hasLength(1));
  });

  for (final restore in [false, true]) {
    test(
      'throwing mutable free intent write preserves committed ${restore ? "opt-out during restore" : "opt-in during deletion"}',
      () async {
        final fixture = await _fixture();
        if (restore) await fixture.servers.delete(fixture.free.single.id);
        final store = (await _failingStore(_removedKey, value: !restore))
          ..throwFailure = true;
        await expectLater(
          restore
              ? fixture.subs.addBuiltInFreeServer()
              : fixture.subs.delete(fixture.freeSub.id),
          throwsStateError,
        );
        expect((await fixture.servers.freeServerSnapshot()).removed, restore);
        expect(
          (await SharedPreferences.getInstance()).getBool(_removedKey),
          restore,
        );
        expect((await store.getAll())['flutter.$_removedKey'], restore);
        store.failKey = null;
        fixture.dispose();
        final reloaded = await _fixture(storage: null);
        expect((await reloaded.servers.freeServerSnapshot()).removed, restore);
        expect(reloaded.free, restore ? isEmpty : hasLength(1));
        if (restore) {
          await reloaded.subs.refreshAll();
          expect(reloaded.free, isEmpty);
        }
      },
    );
  }

  for (final throwing in [false, true]) {
    test(
      'failed first free-intent write removes its mutable cache value (${throwing ? "throw" : "false"})',
      () async {
        SharedPreferences.setMockInitialValues({'unrelated': 'retained'});
        final store =
            _FailingStore(
                await SharedPreferencesStorePlatform.instance.getAll(),
              )
              ..failKey = 'flutter.$_removedKey'
              ..throwFailure = throwing;
        SharedPreferencesStorePlatform.instance = store;
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await expectLater(
          container.read(serversNotifierProvider.future),
          throwsStateError,
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey(_removedKey), isFalse);
        expect(
          (await store.getAll()).containsKey('flutter.$_removedKey'),
          isFalse,
        );
        expect(prefs.getString('unrelated'), 'retained');
        expect(store.writes, ['flutter.$_removedKey']);
      },
    );
  }

  test(
    'bulk profile deletion and subscription deletion preserve opt-out',
    () async {
      final first = await _fixture();
      await first.servers.deleteAll(first.free.map((s) => s.id).toList());
      await first.subs.refreshAll();
      expect(first.free, isEmpty);
      first.dispose();
      final second = await _fixture();
      await second.subs.delete(second.freeSub.id);
      second.dispose();
      final restarted = await _fixture(storage: null);
      expect(restarted.free, isEmpty);
      expect(restarted.adapter.calls, isEmpty);
      expect(restarted.freeSub.serverCount, 0);
    },
  );

  test(
    'deleting custom nodes does not disable or trim free and paid feeds',
    () async {
      final fixture = await _fixture();
      final proxies = const LinkDispatcher().dispatchMultiple(_freeBody);
      await fixture.subs.importProxies(_custom, proxies);
      final custom = fixture.container
          .read(serversNotifierProvider)
          .requireValue
          .where((s) => s.subscriptionId == _custom)
          .toList();
      expect(custom, hasLength(3));
      await fixture.servers.delete(custom.first.id);
      expect((await fixture.servers.freeServerSnapshot()).removed, isFalse);
      await fixture.subs.refreshAll();
      expect(fixture.free, hasLength(1));
      expect(
        fixture.container
            .read(serversNotifierProvider)
            .requireValue
            .where((s) => s.subscriptionId == _custom),
        hasLength(3),
      );
    },
  );

  test('profile deletion during fetch invalidates its response', () async {
    Completer<ResponseBody>? response;
    final started = Completer<void>();
    final fixture = await _fixture(
      respond: (_) {
        if (response == null) return Future.value(_response(_freeBody));
        started.complete();
        return response.future;
      },
    );
    response = Completer<ResponseBody>();
    final update = fixture.subs.refresh(fixture.freeSub.id);
    await started.future;
    await fixture.servers.delete(fixture.free.single.id);
    response.complete(_response(_freeBody));
    await update;
    expect(fixture.free, isEmpty);
    expect((await fixture.servers.freeServerSnapshot()).removed, isTrue);
  });

  test(
    'explicit add restores exactly one; overlapping taps share one request',
    () async {
      final fixture = await _fixture();
      await fixture.servers.delete(fixture.free.single.id);
      final before = fixture.adapter.calls.length;
      await Future.wait(
        List.generate(8, (_) => fixture.subs.addBuiltInFreeServer()),
      );
      expect(fixture.free, hasLength(1));
      expect(fixture.adapter.calls, hasLength(before + 1));
      expect((await fixture.servers.freeServerSnapshot()).removed, isFalse);
      await fixture.subs.addBuiltInFreeServer();
      await fixture.subs.add(builtInSubscriptionUrl);
      expect(fixture.free, hasLength(1));
      expect(fixture.adapter.calls, hasLength(before + 1));
    },
  );

  test(
    'catalog add with an existing free server does not fetch or rotate',
    () async {
      final fixture = await _fixture(draws: [0, 1]);
      final before = fixture.free.single.toJson();
      final calls = fixture.adapter.calls.length;
      await fixture.subs.addBuiltInFreeServer();
      expect(fixture.free.single.toJson(), before);
      expect(fixture.adapter.calls, hasLength(calls));
      expect(fixture.container.read(builtInFreeServerPresentProvider), isTrue);
    },
  );

  test(
    'failed explicit add throws and leaves deletion intent unchanged',
    () async {
      var body = _freeBody;
      final fixture = await _fixture(respond: (_) async => _response(body));
      await fixture.servers.delete(fixture.free.single.id);
      body = '<html>unavailable</html>';
      await expectLater(
        fixture.subs.addBuiltInFreeServer(),
        throwsA(isA<Exception>()),
      );
      expect(fixture.free, isEmpty);
      expect((await fixture.servers.freeServerSnapshot()).removed, isTrue);
      expect(
        fixture.container.read(subscriptionsProvider).requireValue.failures,
        contains(fixture.freeSub.id),
      );
      body = _freeBody;
      await fixture.subs.addBuiltInFreeServer();
      expect(fixture.free, hasLength(1));
      expect(
        fixture.container.read(subscriptionsProvider).requireValue.failures,
        isNot(contains(fixture.freeSub.id)),
      );
    },
  );

  test(
    'delete while explicit restore fetches cannot resurrect free server',
    () async {
      Completer<ResponseBody>? response;
      final started = Completer<void>();
      final fixture = await _fixture(
        respond: (_) {
          if (response == null) return Future.value(_response(_freeBody));
          started.complete();
          return response.future;
        },
      );
      await fixture.servers.delete(fixture.free.single.id);
      response = Completer<ResponseBody>();
      final add = fixture.subs.addBuiltInFreeServer();
      await started.future;
      await fixture.servers.deleteBySubscription(builtInSubscriptionUrl);
      response.complete(_response(_freeBody));
      await add;
      expect(fixture.free, isEmpty);
      expect((await fixture.servers.freeServerSnapshot()).removed, isTrue);
    },
  );

  test(
    'stale fetch lease cannot replace a subsequently restored profile',
    () async {
      final fixture = await _fixture();
      final oldLease = await fixture.servers.freeServerSnapshot();
      await fixture.servers.delete(fixture.free.single.id);
      await fixture.subs.addBuiltInFreeServer();
      final restored = fixture.free.single.toJson();
      final replacement = await fixture.servers.replaceSubscriptionSnapshot(
        builtInSubscriptionUrl,
        const LinkDispatcher().dispatchMultiple(
          'vless://stale@stale.example.test:443?security=tls',
        ),
        freeSnapshot: oldLease,
      );
      expect(replacement.applied, isFalse);
      expect(replacement.count, 1);
      expect(fixture.free.single.toJson(), restored);
    },
  );

  test('explicit add retires the pending first-boot fetch', () async {
    final firstResponse = Completer<ResponseBody>();
    final started = Completer<void>();
    var calls = 0;
    final fixture = await _fixture(
      drainStartup: false,
      respond: (_) {
        if (calls++ == 0) {
          started.complete();
          return firstResponse.future;
        }
        return Future.value(
          _response('vless://fresh@fresh.example.test:443?security=tls#Fresh'),
        );
      },
    );
    await started.future;
    await fixture.subs.addBuiltInFreeServer();
    firstResponse.complete(_response(_freeBody));
    await Future<void>.delayed(Duration.zero);
    expect(fixture.free, hasLength(1));
    expect(fixture.free.single.host, 'fresh.example.test');
    expect(fixture.adapter.calls, hasLength(2));
  });

  test(
    'legacy missing successful free feed is conservatively treated as removed',
    () async {
      final fixture = await _fixture(
        storage: {
          'nexproxy_subscriptions': SubscriptionModel.listToJson([
            SubscriptionModel(
              id: 1,
              url: builtInSubscriptionUrl,
              name: 'HoneyVPN',
              lastUpdated: DateTime(2025),
              updateIntervalHours: 24,
            ),
          ]),
        },
      );
      expect(fixture.free, isEmpty);
      expect(fixture.adapter.calls, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getBool(_removedKey),
        isTrue,
      );
      await fixture.subs.addBuiltInFreeServer();
      expect(fixture.free, hasLength(1));
    },
  );

  test(
    'first-boot fetch failure stays eligible for a successful retry',
    () async {
      var body = '';
      final fixture = await _fixture(respond: (_) async => _response(body));
      expect(fixture.free, isEmpty);
      expect(fixture.freeSub.lastUpdated, isNull);
      expect((await fixture.servers.freeServerSnapshot()).removed, isFalse);
      body = _freeBody;
      await fixture.subs.refreshAll();
      expect(fixture.free, hasLength(1));
      expect(fixture.freeSub.lastUpdated, isNotNull);
    },
  );

  test(
    'restart with an up-to-date free profile keeps it without fetching',
    () async {
      final profile = _stored(10, builtInSubscriptionUrl, selected: true);
      final fixture = await _fixture(
        drainStartup: false,
        storage: {
          'honeyvpn_servers': ServerProfileModel.listToJson([profile]),
          'nexproxy_subscriptions': SubscriptionModel.listToJson([
            SubscriptionModel(
              id: 1,
              url: builtInSubscriptionUrl,
              name: 'HoneyVPN',
              lastUpdated: DateTime.now(),
              updateIntervalHours: 24,
            ),
          ]),
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(fixture.adapter.calls, isEmpty);
      expect(fixture.free.single.toJson(), profile.toJson());
    },
  );

  test(
    'persisted opt-out removes a leftover profile after interrupted deletion',
    () async {
      final fixture = await _fixture(
        storage: {
          _removedKey: true,
          'honeyvpn_servers': ServerProfileModel.listToJson([
            _stored(10, builtInSubscriptionUrl),
            _stored(11, _custom),
          ]),
        },
      );
      expect(fixture.free, isEmpty);
      expect(
        fixture.container
            .read(serversNotifierProvider)
            .requireValue
            .single
            .subscriptionId,
        _custom,
      );
      expect(fixture.adapter.calls, isEmpty);
    },
  );

  test('malformed saved profiles still honor a persisted opt-out', () async {
    final fixture = await _fixture(
      storage: {_removedKey: true, 'honeyvpn_servers': 'not valid json'},
    );
    expect(fixture.free, isEmpty);
    expect(fixture.adapter.calls, isEmpty);
    expect((await fixture.servers.freeServerSnapshot()).removed, isTrue);
  });

  test(
    'random pool includes every distinct parsed protocol without a VLESS preference',
    () {
      final vless = const LinkDispatcher().dispatchMultiple(_freeBody);
      final hy2 = const LinkDispatcher().dispatch(
        'hy2://fake@hy.example.test:443',
      );
      final draws = _DrawRandom([0, 3]);
      final mixed = List.generate(
        2,
        (_) => subscriptionProxies(builtInSubscriptionUrl, [
          hy2,
          ...vless,
          vless.first,
        ], random: draws).single,
      );
      expect(mixed[0].host, 'hy.example.test');
      expect(mixed[1].host, 'third.example.test');
      final onlyHy2 = subscriptionProxies(builtInSubscriptionUrl, [
        hy2,
        hy2,
      ], random: _DrawRandom([0]));
      expect(onlyHy2.single.host, hy2.host);
      expect(
        subscriptionProxies(_custom, [hy2, ...vless, vless.first]),
        hasLength(4),
      );
    },
  );
}
