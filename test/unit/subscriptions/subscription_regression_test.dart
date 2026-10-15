import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../../lib/features/converter/data/parsers/link_dispatcher.dart';
import '../../../lib/features/converter/domain/entities/parsed_proxy.dart';
import '../../../lib/features/servers/data/models/server_profile_model.dart';
import '../../../lib/features/servers/presentation/notifiers/servers_notifier.dart';
import '../../../lib/features/subscriptions/data/models/subscription_model.dart';
import '../../../lib/features/subscriptions/data/services/proxy_identity.dart';
import '../../../lib/features/subscriptions/data/services/subscription_policy.dart';
import '../../../lib/features/subscriptions/data/services/subscription_order.dart';
import '../../../lib/features/subscriptions/presentation/screens/subscriptions_screen.dart';
import '../../../lib/app/l10n/strings.dart';

const customUrl = 'https://example.test/private-subscription';
const secondUrl = 'https://other.test/subscription';
const freeBody =
    'vless://account-a@a.example.test:443?security=tls#A\n'
    'vless://account-b@b.example.test:443?security=tls#B';

ParsedProxy proxy(
  String account, {
  String name = 'Node',
  String host = 'same.example.test',
  String transport = 'tcp',
}) => const LinkDispatcher().dispatch(
  'vless://$account@$host:443?security=tls&type=$transport#$name',
);

class _DrawRandom implements Random {
  _DrawRandom(this.draws);
  final List<int> draws;
  final bounds = <int>[];
  var index = 0;

  @override
  int nextInt(int max) {
    bounds.add(max);
    return draws[index++] % max;
  }

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

class _Adapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) respond;
  final calls = <RequestOptions>[];
  _Adapter(this.respond);

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

class _LatencyNotifier extends ServersNotifier {
  int active = 0;
  int maxActive = 0;
  int tested = 0;

  @override
  Future<double> testLatency(ServerProfileModel server) async {
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    tested++;
    active--;
    return 1;
  }
}

ResponseBody response(
  String text, {
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(text, 200, headers: headers);

Future<(ProviderContainer, _Adapter)> fixture({
  Map<String, Object> storage = const {},
  Future<ResponseBody> Function(RequestOptions)? respond,
}) async {
  SharedPreferences.setMockInitialValues(storage);
  final adapter = _Adapter(respond ?? (_) async => response(freeBody));
  final dio = Dio()..httpClientAdapter = adapter;
  final container = ProviderContainer(
    overrides: [subscriptionDioProvider.overrideWithValue(dio)],
  );
  addTearDown(() {
    container.dispose();
    dio.close(force: true);
  });
  await container.read(subscriptionsProvider.future);
  // Also await the deferred startup refresh, joining its existing lock.
  final builtIn = container
      .read(subscriptionsProvider)
      .requireValue
      .subs
      .firstWhere((s) => s.url == builtInSubscriptionUrl);
  await container.read(subscriptionsProvider.notifier).refresh(builtIn.id);
  return (container, adapter);
}

class _MutableSubscriptionFailure extends InMemorySharedPreferencesStore {
  _MutableSubscriptionFailure(
    Map<String, Object> data, {
    required this.throwing,
  }) : super.withData(data);

  final bool throwing;
  int failuresRemaining = 2;
  final writes = <String>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await super.setValue(valueType, key, value);
    writes.add(key);
    if (key == 'flutter.nexproxy_subscriptions' && failuresRemaining > 0) {
      failuresRemaining--;
      if (throwing) throw StateError('Synthetic subscription storage failure');
      return false;
    }
    return true;
  }
}

void main() {
  for (final throwing in [false, true]) {
    test(
      'subscription reorder recreation preserves committed order after mutable save/restore ${throwing ? "throw" : "false"}',
      () async {
        final (container, _) = await fixture();
        final notifier = container.read(subscriptionsProvider.notifier);
        await notifier.register(customUrl, name: 'Custom');
        final original = container
            .read(subscriptionsProvider)
            .requireValue
            .subs;
        final first = original.first;
        final last = original.last;
        final store = _MutableSubscriptionFailure(
          await SharedPreferencesStorePlatform.instance.getAll(),
          throwing: throwing,
        );
        SharedPreferencesStorePlatform.instance = store;
        await expectLater(
          notifier.move(
            last.id,
            expectedUrl: last.url,
            beforeId: first.id,
            expectedBeforeUrl: first.url,
          ),
          throwsStateError,
        );
        expect(
          container
              .read(subscriptionsProvider)
              .requireValue
              .subs
              .map((row) => row.url),
          original.map((row) => row.url),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(
          SubscriptionModel.listFromJson(
            prefs.getString('nexproxy_subscriptions')!,
          ).map((row) => row.url),
          original.map((row) => row.url),
        );
        expect(store.writes, [
          'flutter.nexproxy_subscriptions',
          'flutter.nexproxy_subscriptions',
        ]);
        container.invalidate(subscriptionsProvider);
        final recreated = await container.read(subscriptionsProvider.future);
        expect(
          recreated.subs.map((row) => row.url),
          original.map((row) => row.url),
        );
      },
    );

    test(
      'queued reorder does not commit the failed manual interval after mutable save/restore ${throwing ? "throw" : "false"}',
      () async {
        final (container, _) = await fixture();
        final notifier = container.read(subscriptionsProvider.notifier);
        await notifier.register(customUrl, name: 'Custom');
        final original = container
            .read(subscriptionsProvider)
            .requireValue
            .subs;
        final first = original.first;
        final custom = original.last;
        final store = _MutableSubscriptionFailure(
          await SharedPreferencesStorePlatform.instance.getAll(),
          throwing: throwing,
        );
        SharedPreferencesStorePlatform.instance = store;
        final rejected = expectLater(
          notifier.setInterval(custom.id, 6),
          throwsStateError,
        );
        final moved = notifier.move(
          custom.id,
          expectedUrl: custom.url,
          beforeId: first.id,
          expectedBeforeUrl: first.url,
        );
        await rejected;
        await moved;
        final current = container.read(subscriptionsProvider).requireValue.subs;
        expect(current.first.url, custom.url);
        expect(current.first.updateIntervalHours, custom.updateIntervalHours);
        expect(
          current.first.updateIntervalOverridden,
          custom.updateIntervalOverridden,
        );
        final prefs = await SharedPreferences.getInstance();
        final cached = SubscriptionModel.listFromJson(
          prefs.getString('nexproxy_subscriptions')!,
        );
        expect(cached.first.updateIntervalHours, custom.updateIntervalHours);
        expect(
          cached.first.updateIntervalOverridden,
          custom.updateIntervalOverridden,
        );
        expect(store.writes, List.filled(3, 'flutter.nexproxy_subscriptions'));
        container.invalidate(subscriptionsProvider);
        final recreated = await container.read(subscriptionsProvider.future);
        expect(recreated.subs.first.url, custom.url);
        expect(
          recreated.subs.first.updateIntervalHours,
          custom.updateIntervalHours,
        );
      },
    );
  }
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'free response containing two nodes stores and reports exactly one',
    () async {
      final (container, _) = await fixture();
      final servers = container.read(serversNotifierProvider).requireValue;
      expect(servers, hasLength(1));
      expect(servers.single.subscriptionId, builtInSubscriptionUrl);
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .single
            .serverCount,
        1,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        SubscriptionModel.listFromJson(
          prefs.getString('nexproxy_subscriptions')!,
        ).single.serverCount,
        1,
      );
    },
  );

  test('repeated free imports still contain exactly one node', () async {
    final (container, _) = await fixture();
    final notifier = container.read(subscriptionsProvider.notifier);
    final proxies = const LinkDispatcher().dispatchMultiple(freeBody);
    await notifier.importProxies(builtInSubscriptionUrl, proxies);
    await notifier.importProxies(
      ' $builtInSubscriptionUrl\x00 ',
      proxies.reversed.toList(),
    );
    final servers = container.read(serversNotifierProvider).requireValue;
    expect(servers, hasLength(1));
    expect(proxies.map((p) => p.host), contains(servers.single.host));
    expect(
      container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .single
          .serverCount,
      1,
    );
  });

  test(
    'custom feed keeps distinct credentials at the same host and port',
    () async {
      final (container, _) = await fixture();
      final notifier = container.read(subscriptionsProvider.notifier);
      final proxies = [
        proxy('first-account'),
        proxy('second-account'),
        proxy('first-account'),
      ];
      expect(await notifier.importProxies(customUrl, proxies), 2);
      expect(await notifier.importProxies(customUrl, proxies), 2);
      final custom = container
          .read(serversNotifierProvider)
          .requireValue
          .where((s) => s.subscriptionId == customUrl)
          .toList();
      expect(custom, hasLength(2));
      expect(custom.map((s) => s.id).toSet(), hasLength(2));
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .firstWhere((s) => s.url == customUrl)
            .serverCount,
        2,
      );
    },
  );

  test('same credentials with different transports are retained', () async {
    final (container, _) = await fixture();
    expect(
      await container.read(subscriptionsProvider.notifier).importProxies(
        customUrl,
        [proxy('same-account'), proxy('same-account', transport: 'ws')],
      ),
      2,
    );
  });

  test(
    'visible subscription count follows individual server deletion',
    () async {
      final (container, _) = await fixture();
      final free = container.read(serversNotifierProvider).requireValue.single;
      expect(
        container.read(subscriptionServerCountProvider(builtInSubscriptionUrl)),
        1,
      );
      await container.read(serversNotifierProvider.notifier).delete(free.id);
      expect(
        container.read(subscriptionServerCountProvider(builtInSubscriptionUrl)),
        0,
      );
    },
  );

  test(
    'manual repeated imports deduplicate within the batch and across batches',
    () async {
      final (container, _) = await fixture();
      final notifier = container.read(serversNotifierProvider.notifier);
      await notifier.addFromProxies([
        proxy('account'),
        proxy('account', name: 'Renamed'),
      ]);
      await notifier.addFromProxy(proxy('account', name: 'Again'));
      await notifier.addFromProxy(proxy('different-account'));
      expect(
        container
            .read(serversNotifierProvider)
            .requireValue
            .where((s) => s.subscriptionId.isEmpty),
        hasLength(2),
      );
    },
  );

  test(
    'parallel imports and latency updates preserve both feeds and selection',
    () async {
      final (container, _) = await fixture();
      final notifier = container.read(serversNotifierProvider.notifier);
      final free = container.read(serversNotifierProvider).requireValue.single;
      await Future.wait([
        notifier.replaceSubscription(customUrl, [proxy('custom')]),
        notifier.replaceSubscription(secondUrl, [proxy('second')]),
        notifier.updateLatency(free.id, 42),
        notifier.selectServer(free),
      ]);
      final servers = container.read(serversNotifierProvider).requireValue;
      expect(servers, hasLength(3));
      expect(servers.map((s) => s.id).toSet(), hasLength(3));
      expect(servers.firstWhere((s) => s.id == free.id).latencyMs, 42);
      expect(servers.where((s) => s.isSelected).single.id, free.id);
      final prefs = await SharedPreferences.getInstance();
      expect(
        ServerProfileModel.listFromJson(prefs.getString('honeyvpn_servers')!),
        hasLength(3),
      );
    },
  );

  test(
    'refresh retains id, selected/favorite state and addedAt after a rename',
    () async {
      final original = ServerProfileModel(
        id: 101,
        protocol: 'vless',
        name: 'Old',
        host: 'same.example.test',
        port: 443,
        configJson: jsonEncode({
          'rawLink': 'vless://account@same.example.test:443?security=tls#Old',
        }),
        subscriptionId: customUrl,
        addedAt: DateTime(2025, 1, 2),
        isSelected: true,
        isFavorite: true,
      );
      final (container, _) = await fixture(
        storage: {
          'honeyvpn_servers': ServerProfileModel.listToJson([original]),
        },
      );
      await container
          .read(serversNotifierProvider.notifier)
          .replaceSubscription(customUrl, [proxy('account', name: 'New')]);
      final updated = container
          .read(serversNotifierProvider)
          .requireValue
          .singleWhere((s) => s.subscriptionId == customUrl);
      expect(updated.id, original.id);
      expect(updated.name, 'New');
      expect(updated.addedAt, original.addedAt);
      expect(updated.isSelected, isTrue);
      expect(updated.isFavorite, isTrue);
    },
  );

  test(
    'provider removing selected node transfers selection within that feed',
    () async {
      final (container, _) = await fixture();
      final notifier = container.read(serversNotifierProvider.notifier);
      await notifier.replaceSubscription(customUrl, [proxy('removed')]);
      final selected = container
          .read(serversNotifierProvider)
          .requireValue
          .firstWhere((s) => s.subscriptionId == customUrl);
      await notifier.selectServer(selected);
      await notifier.replaceSubscription(customUrl, [proxy('replacement')]);
      expect(container.read(selectedServerProvider)!.subscriptionId, customUrl);
      expect(container.read(selectedServerProvider)!.isSelected, isTrue);
    },
  );

  test(
    'legacy duplicate free servers are repaired offline without trimming custom feeds',
    () async {
      ServerProfileModel stored(int id, String url, {bool selected = false}) =>
          ServerProfileModel(
            id: id,
            protocol: 'vless',
            name: '$id',
            host: 'same.example.test',
            port: 443,
            configJson: jsonEncode({
              'rawLink':
                  'vless://account-$id@same.example.test:443?security=tls#$id',
            }),
            subscriptionId: url,
            addedAt: DateTime(2025),
            isSelected: selected,
          );
      final (container, _) = await fixture(
        storage: {
          'honeyvpn_servers': ServerProfileModel.listToJson([
            stored(1, builtInSubscriptionUrl),
            stored(2, builtInSubscriptionUrl, selected: true),
            stored(3, customUrl),
            stored(4, customUrl),
          ]),
        },
        respond: (_) async => response('<html>temporarily unavailable</html>'),
      );
      final servers = container.read(serversNotifierProvider).requireValue;
      expect(
        servers
            .where((s) => s.subscriptionId == builtInSubscriptionUrl)
            .single
            .id,
        2,
      );
      expect(servers.where((s) => s.subscriptionId == customUrl), hasLength(2));
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .single
            .serverCount,
        1,
      );
    },
  );

  test(
    'empty or malformed refresh leaves the last working feed untouched',
    () async {
      var body = freeBody;
      final (container, _) = await fixture(
        respond: (_) async => response(body),
      );
      final before = container
          .read(serversNotifierProvider)
          .requireValue
          .single;
      final sub = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .single;
      body = '';
      await container.read(subscriptionsProvider.notifier).refresh(sub.id);
      expect(
        container.read(serversNotifierProvider).requireValue.single.id,
        before.id,
      );
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .single
            .lastUpdated,
        sub.lastUpdated,
      );
      expect(
        container.read(subscriptionsProvider).requireValue.refreshing,
        isEmpty,
      );
    },
  );

  test(
    'concurrent refresh calls share the request, including the startup refresh',
    () async {
      SharedPreferences.setMockInitialValues({});
      final gate = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = _Adapter((_) {
        if (!started.isCompleted) started.complete();
        return gate.future;
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final container = ProviderContainer(
        overrides: [subscriptionDioProvider.overrideWithValue(dio)],
      );
      addTearDown(() {
        container.dispose();
        dio.close(force: true);
      });
      await container.read(subscriptionsProvider.future);
      await started.future;
      final sub = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .single;
      final first = container
          .read(subscriptionsProvider.notifier)
          .refresh(sub.id);
      final second = container
          .read(subscriptionsProvider.notifier)
          .refreshAll();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.calls, hasLength(1));
      expect(
        container.read(subscriptionsProvider).requireValue.isRefreshing(sub.id),
        isTrue,
      );
      gate.complete(response(freeBody));
      await Future.wait([first, second]);
      expect(
        container.read(serversNotifierProvider).requireValue,
        hasLength(1),
      );
      expect(
        container.read(subscriptionsProvider).requireValue.refreshing,
        isEmpty,
      );
    },
  );

  test(
    'deleted subscription cannot be resurrected by an in-flight response',
    () async {
      final gate = Completer<ResponseBody>();
      final started = Completer<void>();
      final (container, _) = await fixture(
        respond: (options) {
          if (options.uri.toString() == customUrl) {
            if (!started.isCompleted) started.complete();
            return gate.future;
          }
          return Future.value(response(freeBody));
        },
      );
      final notifier = container.read(subscriptionsProvider.notifier);
      await notifier.importProxies(customUrl, [proxy('custom')]);
      final sub = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .firstWhere((s) => s.url == customUrl);
      final pending = notifier.refresh(sub.id);
      await started.future;
      await notifier.delete(sub.id);
      gate.complete(
        response('vless://new@same.example.test:443?security=tls#New'),
      );
      await pending;
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .where((s) => s.id == sub.id),
        isEmpty,
      );
      expect(
        container
            .read(serversNotifierProvider)
            .requireValue
            .where((s) => s.subscriptionId == customUrl),
        isEmpty,
      );
    },
  );

  test(
    'subscription order survives a restart with same-named providers',
    () async {
      final (container, _) = await fixture();
      final notifier = container.read(subscriptionsProvider.notifier);
      await notifier.register(customUrl, name: 'HoneyVPN');
      await notifier.register(secondUrl, name: 'HoneyVPN');
      final original = container.read(subscriptionsProvider).requireValue.subs;
      final second = original.singleWhere((sub) => sub.url == secondUrl);
      final free = original.singleWhere(
        (sub) => sub.url == builtInSubscriptionUrl,
      );
      await notifier.move(
        second.id,
        expectedUrl: second.url,
        beforeId: free.id,
        expectedBeforeUrl: free.url,
      );
      final expectedUrls = [secondUrl, builtInSubscriptionUrl, customUrl];
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.url),
        expectedUrls,
      );
      final prefs = await SharedPreferences.getInstance();
      final saved = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
      final (restarted, _) = await fixture(storage: saved);
      expect(
        restarted
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.url),
        expectedUrls,
      );
      expect(
        restarted
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.name),
        everyElement('HoneyVPN'),
      );
      expect(
        restarted
            .read(serversNotifierProvider)
            .requireValue
            .where((server) => server.subscriptionId == builtInSubscriptionUrl),
        hasLength(1),
      );
    },
  );

  test(
    'an in-flight refresh preserves a drag and the latest metadata',
    () async {
      final gate = Completer<ResponseBody>();
      final started = Completer<void>();
      final (container, _) = await fixture(
        respond: (options) {
          if (options.uri.toString() == customUrl) {
            if (!started.isCompleted) started.complete();
            return gate.future;
          }
          return Future.value(response(freeBody));
        },
      );
      final notifier = container.read(subscriptionsProvider.notifier);
      await notifier.importProxies(customUrl, [proxy('old')]);
      await notifier.register(secondUrl, name: 'Second');
      final original = container.read(subscriptionsProvider).requireValue.subs;
      final custom = original.singleWhere((sub) => sub.url == customUrl);
      final second = original.singleWhere((sub) => sub.url == secondUrl);
      await notifier.setInterval(custom.id, 12);
      final pending = notifier.refresh(custom.id);
      await started.future;
      await notifier.move(
        second.id,
        expectedUrl: second.url,
        beforeId: custom.id,
        expectedBeforeUrl: custom.url,
      );
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .isRefreshing(custom.id),
        isTrue,
      );
      gate.complete(
        response(
          freeBody,
          headers: {
            'profile-title': ['Refreshed provider'],
            'profile-update-interval': ['3'],
          },
        ),
      );
      await pending;
      final state = container.read(subscriptionsProvider).requireValue;
      expect(state.subs.map((sub) => sub.url), [
        builtInSubscriptionUrl,
        secondUrl,
        customUrl,
      ]);
      final refreshed = state.subs.singleWhere((sub) => sub.id == custom.id);
      expect(refreshed.name, 'Refreshed provider');
      expect(refreshed.serverCount, 2);
      expect(refreshed.updateIntervalHours, 12);
      expect(refreshed.updateIntervalOverridden, isTrue);
      expect(refreshed.lastUpdated, isNotNull);
      expect(state.refreshing, isEmpty);
      expect(state.failures, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(
        SubscriptionModel.listFromJson(
          prefs.getString('nexproxy_subscriptions')!,
        ).map((sub) => sub.toJson()),
        state.subs.map((sub) => sub.toJson()),
      );
    },
  );

  test(
    'adding a feed during a drag appends it without undoing the order',
    () async {
      final gate = Completer<ResponseBody>();
      final started = Completer<void>();
      final (container, _) = await fixture(
        respond: (options) {
          if (options.uri.toString() == secondUrl) {
            if (!started.isCompleted) started.complete();
            return gate.future;
          }
          return Future.value(response(freeBody));
        },
      );
      final notifier = container.read(subscriptionsProvider.notifier);
      await notifier.importProxies(customUrl, [proxy('custom')]);
      final original = container.read(subscriptionsProvider).requireValue.subs;
      final custom = original.singleWhere((sub) => sub.url == customUrl);
      final free = original.singleWhere(
        (sub) => sub.url == builtInSubscriptionUrl,
      );
      final addition = notifier.add(secondUrl);
      await started.future;
      await notifier.move(
        custom.id,
        expectedUrl: custom.url,
        beforeId: free.id,
        expectedBeforeUrl: free.url,
      );
      gate.complete(response(freeBody));
      await addition;
      final state = container.read(subscriptionsProvider).requireValue;
      expect(state.subs.map((sub) => sub.url), [
        customUrl,
        builtInSubscriptionUrl,
        secondUrl,
      ]);
      expect(
        orderedSubscriptionGroups(
          container
              .read(serversNotifierProvider)
              .requireValue
              .map((server) => server.subscriptionId),
          state.subs,
        ),
        [customUrl, builtInSubscriptionUrl, secondUrl],
      );
    },
  );

  test(
    'a stale drag does not move a new feed that reused the deleted ID',
    () async {
      final (container, _) = await fixture();
      final notifier = container.read(subscriptionsProvider.notifier);
      await notifier.importProxies(customUrl, [proxy('removed')]);
      final original = container.read(subscriptionsProvider).requireValue.subs;
      final removed = original.singleWhere((sub) => sub.url == customUrl);
      final free = original.singleWhere(
        (sub) => sub.url == builtInSubscriptionUrl,
      );
      await notifier.delete(removed.id);
      await notifier.add(secondUrl);
      final replacement = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .singleWhere((sub) => sub.url == secondUrl);
      expect(
        replacement.id,
        removed.id,
        reason: 'exercises storage-compatible ID reuse',
      );
      final before = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .map((sub) => sub.toJson())
          .toList();
      await notifier.move(
        removed.id,
        expectedUrl: removed.url,
        beforeId: free.id,
        expectedBeforeUrl: free.url,
      );
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.toJson())
            .toList(),
        before,
      );
      final servers = container.read(serversNotifierProvider).requireValue;
      expect(
        servers.where((server) => server.subscriptionId == customUrl),
        isEmpty,
      );
      expect(
        servers.where(
          (server) => server.subscriptionId == builtInSubscriptionUrl,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'a deleted drag anchor cannot bind to another feed with its reused ID',
    () async {
      const thirdUrl = 'https://third.test/subscription';
      final (container, _) = await fixture();
      final notifier = container.read(subscriptionsProvider.notifier);
      await notifier.register(customUrl);
      await notifier.register(secondUrl);
      final original = container.read(subscriptionsProvider).requireValue.subs;
      final free = original.singleWhere(
        (sub) => sub.url == builtInSubscriptionUrl,
      );
      final removedAnchor = original.singleWhere((sub) => sub.url == secondUrl);
      await notifier.delete(removedAnchor.id);
      await notifier.register(thirdUrl);
      final replacement = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .singleWhere((sub) => sub.url == thirdUrl);
      expect(replacement.id, removedAnchor.id);
      await notifier.move(
        free.id,
        expectedUrl: free.url,
        beforeId: removedAnchor.id,
        expectedBeforeUrl: removedAnchor.url,
      );
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.url),
        [customUrl, thirdUrl, builtInSubscriptionUrl],
      );
    },
  );

  testWidgets(
    'subscription drag callback saves both upward and downward moves',
    (tester) async {
      final container = (await tester.runAsync(() async {
        final (container, _) = await fixture();
        final notifier = container.read(subscriptionsProvider.notifier);
        await notifier.register(customUrl, name: 'First');
        await notifier.register(secondUrl, name: 'Second');
        return container;
      }))!;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SubscriptionsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final dynamic callback = tester
            .widget<ReorderableListView>(find.byType(ReorderableListView))
            .onReorder;
        await callback(0, 3);
      });
      await tester.pumpAndSettle();
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.url),
        [customUrl, secondUrl, builtInSubscriptionUrl],
      );
      await tester.runAsync(() async {
        final dynamic callback = tester
            .widget<ReorderableListView>(find.byType(ReorderableListView))
            .onReorder;
        await callback(1, 0);
      });
      await tester.pumpAndSettle();
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.url),
        [secondUrl, customUrl, builtInSubscriptionUrl],
      );
      expect(
        tester.getTopLeft(find.text('Second')).dy,
        lessThan(tester.getTopLeft(find.text('First')).dy),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        SubscriptionModel.listFromJson(
          prefs.getString('nexproxy_subscriptions')!,
        ).map((sub) => sub.url),
        [secondUrl, customUrl, builtInSubscriptionUrl],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'saving a reordered long list preserves its nonzero scroll offset',
    (tester) async {
      final container = (await tester.runAsync(() async {
        final (container, _) = await fixture();
        final notifier = container.read(subscriptionsProvider.notifier);
        for (var index = 0; index < 12; index++) {
          await notifier.register(
            'https://feed-$index.test/subscription',
            name: 'Feed $index',
          );
        }
        return container;
      }))!;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SubscriptionsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(ReorderableListView),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      final beforeList = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      final controller = beforeList.scrollController!;
      final beforeOffset = controller.offset;
      expect(beforeOffset, greaterThan(100));
      final count = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .length;
      await tester.runAsync(() async {
        final dynamic callback = beforeList.onReorder;
        await callback(0, count);
      });
      await tester.pumpAndSettle();
      final afterList = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      expect(afterList.key, isNot(beforeList.key));
      expect(afterList.scrollController, same(controller));
      expect(controller.offset, closeTo(beforeOffset, 0.5));
      expect(
        container.read(subscriptionsProvider).requireValue.subs.last.url,
        builtInSubscriptionUrl,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a saved order cancels earlier drag callbacks', (tester) async {
    final container = (await tester.runAsync(() async {
      final (container, _) = await fixture();
      final notifier = container.read(subscriptionsProvider.notifier);
      await notifier.register(customUrl, name: 'Dragged');
      await notifier.register(secondUrl, name: 'Earlier drop');
      return container;
    }))!;
    final notifier = container.read(subscriptionsProvider.notifier);
    final original = container.read(subscriptionsProvider).requireValue.subs;
    final free = original.singleWhere(
      (sub) => sub.url == builtInSubscriptionUrl,
    );
    final earlier = original.singleWhere((sub) => sub.url == secondUrl);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SubscriptionsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final previousList = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    final initialKey = previousList.key;
    previousList.onReorderStart!(1);
    // Simulate the previous drop's asynchronous save finishing after the next
    // drag started. Membership stays the same, while indices change underneath.
    await tester.runAsync(
      () => notifier.move(
        earlier.id,
        expectedUrl: earlier.url,
        beforeId: free.id,
        expectedBeforeUrl: free.url,
      ),
    );
    await tester.pumpAndSettle();
    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    expect(
      list.key,
      isNot(initialKey),
      reason: 'new row indices invalidate the active gesture',
    );
    previousList.onReorderEnd!(0);
    // Even a delayed callback from the retired list cannot reinterpret its
    // old indices against the new order, while the screen itself is mounted.
    await tester.pump();
    await tester.runAsync(() async {
      final dynamic callback = previousList.onReorder;
      await callback(1, 0);
    });
    await tester.pumpAndSettle();
    expect(
      container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .map((sub) => sub.url),
      [secondUrl, builtInSubscriptionUrl, customUrl],
      reason: 'the completed save remains authoritative after cancellation',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a saved order safely cancels a real drag and allows the next drag',
    (tester) async {
      final container = (await tester.runAsync(() async {
        final (container, _) = await fixture();
        final notifier = container.read(subscriptionsProvider.notifier);
        await notifier.register(customUrl, name: 'Dragged feed');
        await notifier.register(secondUrl, name: 'Earlier drop');
        return container;
      }))!;
      final notifier = container.read(subscriptionsProvider.notifier);
      final original = container.read(subscriptionsProvider).requireValue.subs;
      final dragged = original.singleWhere((sub) => sub.url == customUrl);
      final free = original.singleWhere(
        (sub) => sub.url == builtInSubscriptionUrl,
      );
      final earlier = original.singleWhere((sub) => sub.url == secondUrl);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SubscriptionsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(find.text('Dragged feed')).dy;
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(ValueKey('reorder-subscription-${dragged.id}')),
        ),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.getTopLeft(find.text('Dragged feed')).dy,
        lessThan(before - 20),
      );
      await tester.runAsync(
        () => notifier.move(
          earlier.id,
          expectedUrl: earlier.url,
          beforeId: free.id,
          expectedBeforeUrl: free.url,
        ),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.url),
        [secondUrl, builtInSubscriptionUrl, customUrl],
      );
      expect(find.text('Dragged feed'), findsOneWidget);
      expect(find.text('Earlier drop'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final nextGesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(ValueKey('reorder-subscription-${dragged.id}')),
        ),
      );
      await tester.pump();
      await nextGesture.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 200));
      await nextGesture.up();
      // Drive animation frames and the asynchronous preferences mock together.
      // Riverpod listeners are scheduled in the fake-clock zone, so awaiting
      // one from runAsync would prevent that listener from being delivered.
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        final urls = container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.url)
            .toList();
        if (urls[0] == secondUrl &&
            urls[1] == customUrl &&
            urls[2] == builtInSubscriptionUrl)
          break;
      }
      await tester.pumpAndSettle();
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.url),
        [secondUrl, customUrl, builtInSubscriptionUrl],
      );
      expect(find.text('Dragged feed'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a stationary drop leaves no snapshot for a later keyboard reorder',
    (tester) async {
      final container = (await tester.runAsync(() async {
        final (container, _) = await fixture();
        final notifier = container.read(subscriptionsProvider.notifier);
        await notifier.register(customUrl, name: 'First');
        await notifier.register(secondUrl, name: 'Second');
        return container;
      }))!;
      final notifier = container.read(subscriptionsProvider.notifier);
      final original = container.read(subscriptionsProvider).requireValue.subs;
      final free = original.singleWhere(
        (sub) => sub.url == builtInSubscriptionUrl,
      );
      final second = original.singleWhere((sub) => sub.url == secondUrl);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SubscriptionsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorderStart!(1);
      list.onReorderEnd!(
        1,
      ); // Flutter emits no onReorder for a stationary drop.
      await tester.runAsync(
        () => notifier.move(
          second.id,
          expectedUrl: second.url,
          beforeId: free.id,
          expectedBeforeUrl: free.url,
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final dynamic callback = tester
            .widget<ReorderableListView>(find.byType(ReorderableListView))
            .onReorder;
        await callback(
          1,
          0,
        ); // Accessibility/keyboard invokes this without a drag.
      });
      await tester.pumpAndSettle();
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .map((sub) => sub.url),
        [builtInSubscriptionUrl, secondUrl, customUrl],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('replacing a feed in one frame cancels its active drag', (
    tester,
  ) async {
    final container = (await tester.runAsync(() async {
      final (container, _) = await fixture();
      await container
          .read(subscriptionsProvider.notifier)
          .register(customUrl, name: 'Dragged feed');
      return container;
    }))!;
    final notifier = container.read(subscriptionsProvider.notifier);
    final dragged = container
        .read(subscriptionsProvider)
        .requireValue
        .subs
        .singleWhere((sub) => sub.url == customUrl);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SubscriptionsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('Dragged feed')).dy;
    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(ValueKey('reorder-subscription-${dragged.id}')),
      ),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.getTopLeft(find.text('Dragged feed')).dy,
      lessThan(before - 20),
      reason: 'the gesture must really start a drag before replacing the row',
    );
    // Do not pump between removal and registration: the count seen by the
    // widget remains two and the new URL reuses the dragged feed's numeric ID.
    await tester.runAsync(() async {
      await notifier.delete(dragged.id);
      await notifier.register(secondUrl, name: 'Replacement feed');
    });
    expect(
      container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .singleWhere((sub) => sub.url == secondUrl)
          .id,
      dragged.id,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .map((sub) => sub.url),
      [builtInSubscriptionUrl, secondUrl],
    );
    expect(find.text('Dragged feed'), findsNothing);
    expect(find.text('Replacement feed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('free selection draws one random unique node', () {
    final proxies = const LinkDispatcher().dispatchMultiple(freeBody);
    final draws = _DrawRandom([0, 1, 1]);
    final results = List.generate(
      3,
      (_) => subscriptionProxies(builtInSubscriptionUrl, [
        ...proxies,
        proxies.first,
      ], random: draws).single,
    );
    expect(results.map(proxyIdentity), [
      proxyIdentity(proxies[0]),
      proxyIdentity(proxies[1]),
      proxyIdentity(proxies[1]),
    ]);
    expect(draws.bounds, [2, 2, 2]);
  });

  test(
    'saved NaiveProxy and IPv6 links remain importable after app restart',
    () async {
      final (container, _) = await fixture();
      final proxies = [
        const LinkDispatcher().dispatch(
          'naive+https://user:password@node.example.test:443#Naive',
        ),
        const LinkDispatcher().dispatch(
          'vless://account@[2001:db8::1]:443?security=tls#IPv6',
        ),
      ];
      await container
          .read(serversNotifierProvider.notifier)
          .replaceSubscription(customUrl, proxies);
      final saved = container
          .read(serversNotifierProvider)
          .requireValue
          .where((s) => s.subscriptionId == customUrl)
          .toList();
      for (var i = 0; i < saved.length; i++) {
        final raw =
            (jsonDecode(saved[i].configJson) as Map<String, dynamic>)['rawLink']
                as String;
        expect(
          proxyIdentity(const LinkDispatcher().dispatch(raw)),
          proxyIdentity(proxies[i]),
        );
      }
    },
  );

  test(
    'bulk latency check limits simultaneous native processes to four',
    () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = _LatencyNotifier();
      final container = ProviderContainer(
        overrides: [serversNotifierProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      await container.read(serversNotifierProvider.future);
      await notifier.addFromProxies(
        List.generate(11, (i) => proxy('account-$i')),
      );
      await notifier.testAllLatency();
      expect(notifier.tested, 11);
      expect(notifier.maxActive, 4);
      expect(notifier.active, 0);
    },
  );

  test(
    'unsupported mixed refresh preserves profiles/count/timestamp and successful retry clears failure',
    () async {
      var body = freeBody;
      final (container, _) = await fixture(
        respond: (_) async => response(body),
      );
      final notifier = container.read(subscriptionsProvider.notifier);
      await notifier.add(customUrl);
      final before = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .singleWhere((s) => s.url == customUrl);
      final profiles = container
          .read(serversNotifierProvider)
          .requireValue
          .where((s) => s.subscriptionId == customUrl)
          .toList();
      body =
          'vless://new-account@new.example.test:443?security=tls\n'
          'hy2://fake-password@192.0.2.10:443?pinSHA256=SECRET-FINGERPRINT';
      await notifier.refresh(before.id);
      final after = container.read(subscriptionsProvider).requireValue;
      expect(
        after.failures[before.id],
        SubscriptionFailure.unsupportedConfiguration,
      );
      final unchanged = after.subs.singleWhere((s) => s.id == before.id);
      expect(unchanged.serverCount, before.serverCount);
      expect(unchanged.lastUpdated, before.lastUpdated);
      expect(
        container
            .read(serversNotifierProvider)
            .requireValue
            .where((s) => s.subscriptionId == customUrl)
            .map((s) => s.toJson())
            .toList(),
        profiles.map((s) => s.toJson()).toList(),
      );
      body = freeBody;
      await notifier.refresh(before.id);
      expect(
        container.read(subscriptionsProvider).requireValue.failures,
        isNot(contains(before.id)),
      );
    },
  );

  test(
    'a new unsupported subscription reports failure with zero profiles and no success timestamp',
    () async {
      final (container, _) = await fixture(
        respond: (options) async => response(
          options.uri.toString() == customUrl
              ? 'hy2://fake@192.0.2.10:443?pinSHA256=SECRET'
              : freeBody,
        ),
      );
      await container.read(subscriptionsProvider.notifier).add(customUrl);
      final state = container.read(subscriptionsProvider).requireValue;
      final sub = state.subs.singleWhere((s) => s.url == customUrl);
      expect(
        state.failures[sub.id],
        SubscriptionFailure.unsupportedConfiguration,
      );
      expect(sub.lastUpdated, isNull);
      expect(sub.serverCount, 0);
      expect(
        container
            .read(serversNotifierProvider)
            .requireValue
            .where((s) => s.subscriptionId == customUrl),
        isEmpty,
      );
    },
  );

  test(
    'deleted source late failure cannot contaminate a reused id or block its fresh fetch',
    () async {
      final delayed = Completer<ResponseBody>();
      final started = Completer<void>();
      final (container, adapter) = await fixture(
        respond: (options) {
          if (options.uri.toString() == customUrl) {
            if (!started.isCompleted) started.complete();
            return delayed.future;
          }
          return Future.value(response(freeBody));
        },
      );
      final notifier = container.read(subscriptionsProvider.notifier);
      final oldAdd = notifier.add(customUrl);
      await started.future;
      final oldId = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .singleWhere((s) => s.url == customUrl)
          .id;
      await notifier.delete(oldId);
      await notifier.add(secondUrl);
      final newSub = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .singleWhere((s) => s.url == secondUrl);
      expect(newSub.id, oldId, reason: 'exercises storage-compatible ID reuse');
      expect(
        adapter.calls.where((o) => o.uri.toString() == secondUrl),
        hasLength(1),
      );
      expect(newSub.serverCount, 2);
      delayed.complete(response('hy2://fake@192.0.2.10:443?pinSHA256=SECRET'));
      await oldAdd;
      final state = container.read(subscriptionsProvider).requireValue;
      expect(state.subs.any((s) => s.url == customUrl), isFalse);
      expect(state.failures, isNot(contains(newSub.id)));
      expect(
        state.subs.singleWhere((s) => s.id == newSub.id).lastUpdated,
        newSub.lastUpdated,
      );
      expect(state.refreshing, isEmpty);
    },
  );

  test(
    'new TLS/hopping options survive persisted raw links and remain distinct identities',
    () async {
      final (container, _) = await fixture();
      final first = const LinkDispatcher().dispatch(
        'vless://account@same.example.test:443?security=tls&type=ws&path=%2F%252F&alpn=h2&allowInsecure=1',
      );
      final second = const LinkDispatcher().dispatch(
        'vless://account@same.example.test:443?security=tls&type=ws&path=%2F%252F&alpn=http%2F1.1',
      );
      final hy2 = const LinkDispatcher().dispatch(
        'hy2://user%3Apass%40word%252F@same.example.test:443?obfs=salamander&obfs-password=fake%26obfs%3Dpassword&mport=443,5000-5002&hopInterval=30s',
      );
      final proxies = [first, second, hy2];
      await container
          .read(serversNotifierProvider.notifier)
          .replaceSubscription(customUrl, proxies);
      final saved = container
          .read(serversNotifierProvider)
          .requireValue
          .where((s) => s.subscriptionId == customUrl)
          .toList();
      expect(saved, hasLength(3));
      for (var i = 0; i < saved.length; i++) {
        final raw =
            (jsonDecode(saved[i].configJson) as Map<String, dynamic>)['rawLink']
                as String;
        expect(
          proxyIdentity(const LinkDispatcher().dispatch(raw)),
          proxyIdentity(proxies[i]),
        );
      }
    },
  );

  for (final locale in ['ru', 'en']) {
    testWidgets(
      '$locale subscription failure shows a safe tooltip and preserves cached data',
      (tester) async {
        final (container, before, profiles) = (await tester.runAsync(() async {
          var body = freeBody;
          final (container, _) = await fixture(
            respond: (_) async => response(body),
          );
          final notifier = container.read(subscriptionsProvider.notifier);
          final builtIn = container
              .read(subscriptionsProvider)
              .requireValue
              .subs
              .single;
          final profiles = container
              .read(serversNotifierProvider)
              .requireValue
              .map((server) => server.toJson())
              .toList();
          body =
              'hy2://fake-password@192.0.2.10:443?pinSHA256=SECRET-FINGERPRINT';
          await notifier.refresh(builtIn.id);
          await notifier.add(customUrl);
          return (container, builtIn.toJson(), profiles);
        }))!;
        final state = container.read(subscriptionsProvider).requireValue;
        final cached = state.subs.singleWhere(
          (sub) => sub.url == builtInSubscriptionUrl,
        );
        final unsupported = state.subs.singleWhere(
          (sub) => sub.url == customUrl,
        );
        expect(state.failures, {
          cached.id: SubscriptionFailure.unsupportedConfiguration,
          unsupported.id: SubscriptionFailure.unsupportedConfiguration,
        });
        expect(cached.toJson(), before);
        expect(unsupported.serverCount, 0);
        expect(unsupported.lastUpdated, isNull);
        expect(
          container
              .read(serversNotifierProvider)
              .requireValue
              .map((server) => server.toJson())
              .toList(),
          profiles,
        );
        final strings = S(locale);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: ProviderScope(
              overrides: [stringsProvider.overrideWithValue(strings)],
              child: const MaterialApp(home: SubscriptionsScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.warning_rounded), findsNWidgets(2));
        final warnings = find.byTooltip(
          strings.subscriptionRefreshFailureTooltip,
        );
        expect(warnings, findsNWidgets(2));
        await tester.longPress(warnings.first);
        await tester.pumpAndSettle();
        expect(
          find.text(strings.subscriptionRefreshFailureTooltip),
          findsOneWidget,
        );
        expect(find.textContaining('SECRET'), findsNothing);
        expect(tester.takeException(), isNull);
        // Dispose widgets before the shared provider fixture is torn down.
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
