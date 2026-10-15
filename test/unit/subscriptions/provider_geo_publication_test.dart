import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/provider_geo_bundle.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/provider_geo_runtime.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/provider_routing_parser.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/models/subscription_model.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscription_policy.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/domain/entities/provider_geo_state.dart';
import 'package:honeyproxyutility/features/subscriptions/domain/entities/provider_routing_metadata.dart';

const _url = 'https://provider.example.test/feed';
const _feed =
    'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@192.0.2.10:443?security=none#Proxy';
String _body(String domain) =>
    _feed +
    '\n' +
    'happ://routing/add/' +
    base64.encode(
      utf8.encode(
        jsonEncode({
          'DirectSites': ['full:$domain'],
        }),
      ),
    );

class _Adapter implements HttpClientAdapter {
  String body = _feed;
  Map<String, List<String>> headers = {};
  Completer<void>? responseGate;
  var fetches = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    fetches++;
    await responseGate?.future;
    return ResponseBody.fromString(body, 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

class _RetryAdapter implements HttpClientAdapter {
  var geoCalls = 0;
  final geoHeaders = <Map<String, dynamic>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    if (options.uri.path.endsWith('.dat')) {
      geoHeaders.add(Map.of(options.headers));
      if (++geoCalls == 1) {
        return ResponseBody.fromBytes(
          [0],
          200,
          headers: {
            'etag': ['"broken"'],
          },
        );
      }
      // Synthetic official geodat.proto: RU with 192.0.2.0/24.
      return ResponseBody.fromBytes(
        [10, 14, 10, 2, 82, 85, 18, 8, 10, 4, 192, 0, 2, 0, 16, 24],
        200,
        headers: {
          'etag': ['"fixed"'],
        },
      );
    }
    final directive =
        'happ://routing/add/' +
        base64.encode(
          utf8.encode(
            jsonEncode({
              'Geoipurl': 'https://provider.example.test/geoip.dat',
              'DirectIp': ['geoip:ru'],
            }),
          ),
        );
    return ResponseBody.fromString(
      '$_feed\n$directive',
      200,
      headers: {
        'profile-update-interval': ['3'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Runtime extends ProviderGeoRuntime {
  _Runtime() : super(dio: Dio());
  final calls = <({ProviderRoutingMetadata metadata, bool force})>[];
  final pending = <Completer<void>>[];
  var delay = false, fail = false, released = 0, collections = 0;
  @override
  Future<ProviderGeoPrepared> prepare(
    ProviderRoutingMetadata metadata, {
    required String subscriptionUrl,
    ProviderGeoReference? previous,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    calls.add((metadata: metadata, force: forceRefresh));
    if (delay) {
      final gate = Completer<void>();
      pending.add(gate);
      await gate.future;
    }
    if (fail) throw const ProviderGeoException(ProviderGeoIssue.download);
    final bundle = const ProviderGeoCompiler().compile(
      metadata.commands.single.profile!,
      scope: providerGeoScope(metadata.subscriptionId, subscriptionUrl),
      metadataDigest: providerMetadataDigest(metadata),
    );
    return ProviderGeoPrepared(
      ProviderGeoReference(
        scope: bundle.scope,
        bundleDigest: bundle.digest,
        metadataDigest: bundle.metadataDigest,
        updatedAt: DateTime.utc(2026),
      ),
      bundle,
      release: () async {
        released++;
      },
    );
  }

  @override
  Future<void> collectGarbage() async {
    collections++;
  }
}

class _Fixture {
  _Fixture(this.container, this.runtime, this.adapter);
  final ProviderContainer container;
  final _Runtime runtime;
  final _Adapter adapter;
  SubscriptionsNotifier get notifier =>
      container.read(subscriptionsProvider.notifier);
  SubscriptionModel get sub => container
      .read(subscriptionsProvider)
      .requireValue
      .subs
      .singleWhere((s) => s.url == _url);
}

Future<_Fixture> _fixture() async {
  SharedPreferences.setMockInitialValues({
    'honeyvpn_free_server_removed_v1': true,
    'nexproxy_subscriptions': SubscriptionModel.listToJson([
      SubscriptionModel(
        id: 1,
        url: builtInSubscriptionUrl,
        name: 'HoneyVPN',
        lastUpdated: DateTime.now(),
        updateIntervalHours: 24,
      ),
      SubscriptionModel(
        id: 2,
        url: _url,
        name: 'Provider',
        lastUpdated: DateTime.now(),
      ),
    ]),
  });
  final runtime = _Runtime(), adapter = _Adapter();
  final dio = Dio()..httpClientAdapter = adapter;
  final container = ProviderContainer(
    overrides: [
      subscriptionDioProvider.overrideWithValue(dio),
      providerGeoRuntimeProvider.overrideWithValue(runtime),
    ],
  );
  addTearDown(() {
    container.dispose();
    dio.close(force: true);
  });
  await container.read(subscriptionsProvider.future);
  await container.read(serversNotifierProvider.future);
  await Future<void>.delayed(Duration.zero);
  return _Fixture(container, runtime, adapter);
}

Future<void> _wait(bool Function() ready) async {
  for (var n = 0; n < 100 && !ready(); n++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final all in [false, true]) {
    test(
      '${all ? 'refreshAll' : 'refresh'} forces only its own operation and upgrades an in-flight automatic refresh',
      () async {
        final f = await _fixture();
        f.adapter.body = _body('cached.example.test');
        Future<void> manual() =>
            all ? f.notifier.refreshAll() : f.notifier.refresh(f.sub.id);

        await manual();
        await f.notifier.add(_url);
        expect(f.runtime.calls.map((call) => call.force), [true, false]);

        f.adapter.responseGate = Completer<void>();
        final automatic = f.notifier.add(_url);
        await _wait(() => f.adapter.fetches == 3);
        final forced = manual();
        // The public methods await provider readiness before joining the lock.
        await Future<void>.delayed(Duration.zero);
        f.adapter.responseGate!.complete();
        await Future.wait([automatic, forced]);
        expect(f.adapter.fetches, 3);
        expect(f.runtime.calls.map((call) => call.force), [true, false, true]);

        await f.notifier.add(_url);
        expect(f.runtime.calls.map((call) => call.force), [
          true,
          false,
          true,
          false,
        ]);
      },
    );
  }
  test(
    'large plain feed with no routing declaration keeps optional geo absent',
    () async {
      final f = await _fixture();
      f.adapter.body =
          '$_feed\n' + 'x' * (ProviderRoutingParser.maximumBodyBytes + 1);
      await f.notifier.refresh(f.sub.id);
      expect(f.sub.providerGeoStatus, ProviderGeoStatus.absent);
      expect(f.sub.providerGeoIssue, isNull);
      expect(
        f.container.read(subscriptionsProvider).requireValue.failures,
        isEmpty,
      );
      expect(
        await f.runtime.resolveForSubscription(
          f.sub,
          const AppSettings(geoRoutingMode: GeoRoutingMode.combined),
        ),
        isNull,
      );
      expect(
        f.container
            .read(serversNotifierProvider)
            .requireValue
            .where((s) => s.subscriptionId == _url),
        hasLength(1),
      );
    },
  );
  test(
    'malformed declared rules in a base64 feed remain an explicit geo failure',
    () async {
      final f = await _fixture();
      final invalid =
          'happ://routing/add/' +
          base64.encode(utf8.encode(jsonEncode({'RouteOrder': 'unknown'})));
      f.adapter.body = base64.encode(utf8.encode('$_feed\n$invalid'));
      await f.notifier.refresh(f.sub.id);
      expect(f.sub.providerGeoStatus, ProviderGeoStatus.unavailable);
      expect(f.sub.providerGeoIssue, ProviderGeoIssue.invalid);
      expect(
        f.container.read(subscriptionsProvider).requireValue.failures,
        isEmpty,
      );
      expect(
        f.container
            .read(serversNotifierProvider)
            .requireValue
            .where((s) => s.subscriptionId == _url),
        hasLength(1),
      );
    },
  );
  test(
    'next scheduled-style feed refresh retries a broken cached DAT before weekly TTL',
    () async {
      SharedPreferences.setMockInitialValues({
        'honeyvpn_free_server_removed_v1': true,
        'nexproxy_subscriptions': SubscriptionModel.listToJson([
          SubscriptionModel(
            id: 1,
            url: builtInSubscriptionUrl,
            name: 'HoneyVPN',
            lastUpdated: DateTime.now(),
            updateIntervalHours: 24,
          ),
          SubscriptionModel(
            id: 2,
            url: _url,
            name: 'Provider',
            lastUpdated: DateTime.now(),
          ),
        ]),
      });
      final directory = await Directory.systemTemp.createTemp(
        'pgeo-retry-public-',
      );
      final adapter = _RetryAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final runtime = ProviderGeoRuntime(
        dio: dio,
        directory: () async => directory,
      );
      final container = ProviderContainer(
        overrides: [
          subscriptionDioProvider.overrideWithValue(dio),
          providerGeoRuntimeProvider.overrideWithValue(runtime),
        ],
      );
      addTearDown(() async {
        container.dispose();
        dio.close(force: true);
        await directory.delete(recursive: true);
      });
      await container.read(subscriptionsProvider.future);
      final notifier = container.read(subscriptionsProvider.notifier);
      // add(existing) uses the same forceGeo=false path as periodic refresh.
      await notifier.add(_url);
      SubscriptionModel current() => container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .singleWhere((s) => s.url == _url);
      expect(current().providerGeoStatus, ProviderGeoStatus.unavailable);
      expect(current().providerGeoIssue, ProviderGeoIssue.invalid);
      expect(current().updateIntervalHours, 3);
      expect(adapter.geoCalls, 1);
      await notifier.add(_url);
      expect(adapter.geoCalls, 2);
      expect(adapter.geoHeaders.last['If-None-Match'], '"broken"');
      expect(current().providerGeoStatus, ProviderGeoStatus.ready);
      expect(current().providerGeoIssue, isNull);
      expect(current().providerGeo, isNotNull);
      expect(
        container.read(subscriptionsProvider).requireValue.failures,
        isEmpty,
      );
    },
  );
  test(
    'initial HTTP import adopts provider interval/title without a second feed fetch',
    () async {
      final f = await _fixture();
      await f.notifier.importProxies(
        _url,
        const LinkDispatcher().dispatchMultiple(_feed),
      );
      await f.notifier.adoptProviderResponse(_url, _feed, {
        'Profile-Update-Interval': ['3'],
        'profile-title': ['base64:' + base64.encode(utf8.encode('Magic'))],
      });
      expect(f.sub.name, 'Magic');
      expect(f.sub.updateIntervalHours, 3);
      expect(f.sub.updateIntervalOverridden, false);
      expect(f.runtime.calls, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      final persisted = SubscriptionModel.listFromJson(
        prefs.getString('nexproxy_subscriptions')!,
      ).singleWhere((s) => s.url == _url);
      expect(persisted.updateIntervalHours, 3);
      await f.notifier.setInterval(f.sub.id, 12);
      await f.notifier.adoptProviderResponse(_url, _feed, {
        'profile-update-interval': ['3'],
      });
      expect(f.sub.updateIntervalHours, 12);
      expect(f.sub.updateIntervalOverridden, true);
    },
  );
  test(
    'ambiguous/unbounded provider headers do not overwrite subscription metadata',
    () async {
      final f = await _fixture();
      for (final value in ['0', '-1', '169', '99999999999999999']) {
        await f.notifier.adoptProviderResponse(_url, _feed, {
          'profile-update-interval': [value],
        });
        expect(f.sub.updateIntervalHours, 0);
      }
      await f.notifier.adoptProviderResponse(_url, _feed, {
        'profile-update-interval': ['3'],
        'PROFILE-UPDATE-INTERVAL': ['6'],
        'profile-title': ['Unsafe\nTitle'],
      });
      expect(f.sub.updateIntervalHours, 0);
      expect(f.sub.name, 'Provider');
    },
  );
  test(
    'prepared immutable bundle lease stays until persisted reference and then releases',
    () async {
      final f = await _fixture();
      await f.notifier.adoptProviderResponse(
        _url,
        _body('first.example.test'),
        {},
      );
      expect(f.sub.providerGeoStatus, ProviderGeoStatus.ready);
      expect(f.runtime.released, 1);
      expect(f.runtime.calls.single.force, true);
      final prefs = await SharedPreferences.getInstance();
      final persisted = SubscriptionModel.listFromJson(
        prefs.getString('nexproxy_subscriptions')!,
      ).singleWhere((s) => s.url == _url);
      expect(
        persisted.providerGeo!.bundleDigest,
        f.sub.providerGeo!.bundleDigest,
      );
      expect(persisted.providerRouting!.subscriptionId, f.sub.id);
    },
  );
  test(
    'deleting subscription during preparation rejects late result and releases lease',
    () async {
      final f = await _fixture();
      f.runtime.delay = true;
      final adding = f.notifier.adoptProviderResponse(
        _url,
        _body('late.example.test'),
        {},
      );
      await _wait(() => f.runtime.pending.length == 1);
      await f.notifier.delete(f.sub.id);
      expect(f.runtime.collections, 1);
      f.runtime.pending.single.complete();
      await adding;
      expect(f.runtime.released, 1);
      expect(
        f.container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .any((s) => s.url == _url),
        false,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        SubscriptionModel.listFromJson(
          prefs.getString('nexproxy_subscriptions')!,
        ).any((s) => s.url == _url),
        false,
      );
    },
  );
  test(
    'new import publication wins over retired in-flight geo result',
    () async {
      final f = await _fixture();
      f.runtime.delay = true;
      final old = f.notifier.adoptProviderResponse(
        _url,
        _body('old.example.test'),
        {},
      );
      await _wait(() => f.runtime.pending.length == 1);
      final fresh = f.notifier.adoptProviderResponse(
        _url,
        _body('new.example.test'),
        {},
      );
      await _wait(() => f.runtime.pending.length == 2);
      f.runtime.pending.last.complete();
      await fresh;
      final chosen = f.sub.providerGeo!.bundleDigest;
      f.runtime.pending.first.complete();
      await old;
      expect(f.sub.providerGeo!.bundleDigest, chosen);
      expect(
        f
            .sub
            .providerRouting!
            .commands
            .single
            .profile!
            .directSites
            .single
            .value,
        'new.example.test',
      );
      expect(f.runtime.released, 2);
    },
  );
  test(
    'geo download failure preserves last-good rules while proxy feed refresh succeeds',
    () async {
      final f = await _fixture();
      await f.notifier.adoptProviderResponse(
        _url,
        _body('good.example.test'),
        {},
      );
      final good = f.sub.providerGeo!.bundleDigest;
      f.runtime.fail = true;
      f.adapter.body = _body('new.example.test');
      await f.notifier.refresh(f.sub.id);
      expect(f.sub.providerGeoStatus, ProviderGeoStatus.stale);
      expect(f.sub.providerGeoIssue, ProviderGeoIssue.download);
      expect(f.sub.providerGeo!.bundleDigest, good);
      expect(
        f.container.read(subscriptionsProvider).requireValue.failures,
        isEmpty,
      );
      expect(
        f.container
            .read(serversNotifierProvider)
            .requireValue
            .where((s) => s.subscriptionId == _url),
        hasLength(1),
      );
      expect(f.runtime.calls.last.force, true);
      final prefs = await SharedPreferences.getInstance();
      final stored = SubscriptionModel.listFromJson(
        prefs.getString('nexproxy_subscriptions')!,
      ).singleWhere((s) => s.url == _url);
      expect(stored.providerGeoIssue, ProviderGeoIssue.download);
      f.runtime.fail = false;
      await f.notifier.refresh(f.sub.id);
      expect(f.sub.providerGeoStatus, ProviderGeoStatus.ready);
      expect(f.sub.providerGeoIssue, isNull);
    },
  );
  test(
    'interrupted pending metadata state reloads honestly with and without last-good',
    () async {
      final f = await _fixture();
      await f.notifier.adoptProviderResponse(
        _url,
        _body('good.example.test'),
        {},
      );
      expect(
        SubscriptionModel.fromJson({
          ...f.sub.toJson(),
          'providerGeoStatus': 'updating',
        }).providerGeoStatus,
        ProviderGeoStatus.stale,
      );
      final noGood = Map<String, dynamic>.from(f.sub.toJson())
        ..remove('providerGeo')
        ..['providerGeoStatus'] = 'updating';
      expect(
        SubscriptionModel.fromJson(noGood).providerGeoStatus,
        ProviderGeoStatus.unavailable,
      );
    },
  );
}
