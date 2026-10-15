import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/vpn_core_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/singbox_datasource.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/apple_vpn_datasource.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/provider_geo_bundle.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/provider_geo_runtime.dart';
import 'package:honeyproxyutility/features/subscriptions/data/models/subscription_model.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/domain/entities/provider_geo_state.dart';

class _FakeSource extends VpnDatasource {
  @override
  bool get requiresNativeSessionDiscovery => false;
  _FakeSource({bool autoGrant = true}) : super(onStatusChanged: (_) {}) {
    if (autoGrant) permission.complete(true);
  }
  final permission = Completer<bool>();
  final permissionRequested = Completer<void>();
  final startRequested = Completer<void>();
  final stopRequested = Completer<void>();
  Future<bool> check = Future.value(false);
  Future<void>? startResult;
  Future<void>? stopResult;
  Object? initializationError;
  void Function(VpnCoreStatus)? emitStatus;
  void Function(String)? emitError;
  var starts = 0;
  var stops = 0;
  var statusReads = 0;
  var disposed = false;
  ProviderGeoBundle? providerRouting;

  @override
  void bindProviderRouting(ProviderGeoBundle? bundle) =>
      providerRouting = bundle;

  @override
  Future<bool> checkRunning() => check;
  @override
  Future<VpnCoreStatus?> readCurrentStatus() async {
    statusReads++;
    return await check ? const VpnCoreStatus(state: 'CONNECTED') : null;
  }

  @override
  Future<void> initialize() async {
    if (initializationError != null) throw initializationError!;
  }

  @override
  Future<bool> requestPermission() {
    permissionRequested.complete();
    return permission.future;
  }

  @override
  Future<void> start(
    ParsedProxy proxy, {
    ConnectionMode mode = ConnectionMode.tunnel,
    AppSettings settings = const AppSettings(),
  }) {
    starts++;
    startRequested.complete();
    return startResult ?? Future.value();
  }

  @override
  Future<void> stop() {
    stops++;
    if (!stopRequested.isCompleted) stopRequested.complete();
    return stopResult ?? Future.value();
  }

  @override
  void dispose() => disposed = true;
}

class _GeoRuntime extends ProviderGeoRuntime {
  _GeoRuntime({this.bundle, this.failure, this.gate}) : super(dio: Dio());
  final ProviderGeoBundle? bundle;
  final ProviderGeoException? failure;
  final Completer<ProviderGeoBundle?>? gate;
  final resolving = Completer<void>();
  SubscriptionModel? selected;
  var calls = 0;

  @override
  Future<ProviderGeoBundle?> resolveForSubscription(
    SubscriptionModel? subscription,
    AppSettings settings,
  ) async {
    selected = subscription;
    calls++;
    resolving.complete();
    if (failure != null) throw failure!;
    return gate == null ? bundle : await gate!.future;
  }
}

class _SavedSubscriptions extends SubscriptionsNotifier {
  _SavedSubscriptions(this.subscriptions);
  final List<SubscriptionModel> subscriptions;
  @override
  Future<SubscriptionsState> build() async =>
      SubscriptionsState(subs: subscriptions);
}

class _Fixture {
  final ProviderContainer container;
  var disposed = false;
  _Fixture(this.container);
  ConnectionNotifier get notifier =>
      container.read(connectionNotifierProvider.notifier);
  NexConnectionState get state => container.read(connectionNotifierProvider);
  void dispose() {
    if (!disposed) container.dispose();
    disposed = true;
  }
}

Future<_Fixture> _fixture(
  List<_FakeSource> sources, {
  String locale = 'en',
  AppSettings? savedSettings,
  ProviderGeoRuntime? providerGeo,
  List<SubscriptionModel>? subscriptions,
}) async {
  SharedPreferences.setMockInitialValues({
    'honeyvpn_settings': (savedSettings ?? AppSettings(locale: locale))
        .toJsonString(),
  });
  var index = 0;
  final fixture = _Fixture(
    ProviderContainer(
      overrides: [
        if (providerGeo != null)
          providerGeoRuntimeProvider.overrideWithValue(providerGeo),
        if (subscriptions != null)
          subscriptionsProvider.overrideWith(
            () => _SavedSubscriptions(subscriptions),
          ),
        vpnDatasourceFactoryProvider.overrideWithValue(({
          required void Function(VpnCoreStatus) onStatusChanged,
          void Function(String)? onError,
        }) {
          final source = sources[index++];
          source.emitStatus = onStatusChanged;
          source.emitError = onError;
          return source;
        }),
      ],
    ),
  );
  addTearDown(fixture.dispose);
  fixture.container.read(connectionNotifierProvider);
  await Future<void>.delayed(Duration.zero);
  return fixture;
}

ServerProfileModel _server({
  int id = 1,
  String? link,
  String subscriptionId = '',
}) => ServerProfileModel(
  id: id,
  protocol: 'vless',
  name: 'Server $id',
  host: 'example.com',
  port: 443,
  configJson: jsonEncode({
    'rawLink':
        link ??
        'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@example.com:443?security=none&type=tcp#Node',
  }),
  subscriptionId: subscriptionId,
  addedAt: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final locale in ['ru', 'en']) {
    test(
      'invalid saved DNS fails before permission/core start ($locale)',
      () async {
        final probe = _FakeSource();
        final fixture = await _fixture(
          [probe],
          savedSettings: AppSettings(
            locale: locale,
            dnsPreset: DnsPreset.custom,
            customDnsUrl: 'https://dns.invalid/query?token=private-test-token',
          ),
        );
        await fixture.notifier.connect(_server());
        expect(fixture.state.status, ConnectionStatus.error);
        expect(
          fixture.state.errorMessage,
          fixture.container.read(stringsProvider).customDnsExtrasUnsupported,
        );
        expect(
          fixture.state.errorMessage,
          isNot(contains('private-test-token')),
        );
        expect(probe.starts, 0);
        expect(probe.permissionRequested.isCompleted, isFalse);
        probe.emitStatus!(const VpnCoreStatus(state: 'CONNECTED'));
        expect(fixture.state.status, ConnectionStatus.error);
      },
    );
  }

  test('disconnect while permission is pending prevents VPN start', () async {
    final source = _FakeSource(autoGrant: false);
    final fixture = await _fixture([_FakeSource(), source]);
    final connecting = fixture.notifier.connect(_server());
    await source.permissionRequested.future;
    await fixture.notifier.disconnect();
    source.permission.complete(true);
    await connecting;
    source.emitStatus!(VpnCoreStatus(state: 'CONNECTED'));
    expect(source.starts, 0);
    expect(source.stops, 1);
    expect(source.disposed, isTrue);
    expect(fixture.state.status, ConnectionStatus.disconnected);
  });

  test(
    'late permission errors and events cannot overwrite a new session',
    () async {
      final old = _FakeSource(autoGrant: false);
      final current = _FakeSource();
      final fixture = await _fixture([_FakeSource(), old, current]);
      final first = fixture.notifier.connect(_server());
      await old.permissionRequested.future;
      await fixture.notifier.disconnect();
      await fixture.notifier.connect(_server(id: 2));
      current.emitStatus!(VpnCoreStatus(state: 'CONNECTED'));
      old.permission.completeError(StateError('old permission failure'));
      old.emitError!('old native failure');
      old.emitStatus!(VpnCoreStatus(state: 'DISCONNECTED'));
      await first;
      expect(fixture.state.status, ConnectionStatus.connected);
      expect(fixture.state.activeServer?.id, 2);
      expect(fixture.state.errorMessage, isNull);
    },
  );

  test(
    'a cancelled in-flight start is stopped after completion, without revival',
    () async {
      final start = Completer<void>();
      final source = _FakeSource()..startResult = start.future;
      final fixture = await _fixture([_FakeSource(), source]);
      final connecting = fixture.notifier.connect(_server());
      await source.startRequested.future;
      final disconnecting = fixture.notifier.disconnect();
      await fixture.notifier.disconnect();
      source.emitStatus!(VpnCoreStatus(state: 'CONNECTED'));
      expect(fixture.state.status, ConnectionStatus.disconnecting);
      start.complete();
      await Future.wait([connecting, disconnecting]);
      expect(source.stops, 1);
      expect(source.disposed, isTrue);
      expect(fixture.state.status, ConnectionStatus.disconnected);
    },
  );

  test('disconnect cancels a pending startup restoration', () async {
    final check = Completer<bool>();
    final probe = _FakeSource()..check = check.future;
    final fixture = await _fixture([probe]);
    await fixture.notifier.disconnect();
    check.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(probe.disposed, isTrue);
    expect(fixture.state.status, ConnectionStatus.disconnected);
  });

  test('permission result after provider disposal is ignored safely', () async {
    final source = _FakeSource(autoGrant: false);
    final fixture = await _fixture([_FakeSource(), source]);
    final connecting = fixture.notifier.connect(_server());
    await source.permissionRequested.future;
    fixture.dispose();
    source.permission.complete(true);
    await connecting;
    expect(source.starts, 0);
    expect(source.disposed, isTrue);
  });

  test('stats from a failed native session cannot restore CONNECTED', () async {
    final source = _FakeSource();
    final fixture = await _fixture([_FakeSource(), source]);
    await fixture.notifier.connect(_server());
    source.emitError!('native startup failed');
    source.emitStatus!(VpnCoreStatus(state: 'CONNECTED'));
    expect(fixture.state.status, ConnectionStatus.error);
    expect(fixture.state.errorMessage, S('en').vpnUnknownFailure);
  });

  test('provider routing binds the selected subscription snapshot', () async {
    final bundle = ProviderGeoBundle.fromJson({
      'schema': 1,
      'scope': 'a'.padLeft(64, 'a'),
      'metadataDigest': 'b'.padLeft(64, 'b'),
      'groups': {
        'block': <Map<String, dynamic>>[],
        'proxy': <Map<String, dynamic>>[],
        'direct': [
          {
            'domain': ['example.invalid'],
          },
        ],
      },
    });
    final runtime = _GeoRuntime(bundle: bundle);
    final source = _FakeSource();
    final fixture = await _fixture(
      [_FakeSource(), source],
      savedSettings: const AppSettings(geoRoutingMode: GeoRoutingMode.combined),
      providerGeo: runtime,
      subscriptions: const [
        SubscriptionModel(
          id: 10,
          url: 'https://other.example.invalid',
          name: 'Other',
        ),
        SubscriptionModel(
          id: 11,
          url: 'https://selected.example.invalid',
          name: 'Selected',
        ),
      ],
    );
    await fixture.notifier.connect(
      _server(subscriptionId: 'https://selected.example.invalid'),
    );
    expect(runtime.selected?.id, 11);
    expect(source.providerRouting, same(bundle));
    expect(source.starts, 1);
  });

  test(
    'disconnect cancels pending provider routing before native start',
    () async {
      final gate = Completer<ProviderGeoBundle?>();
      final runtime = _GeoRuntime(gate: gate);
      final fixture = await _fixture(
        [_FakeSource()],
        savedSettings: const AppSettings(
          geoRoutingMode: GeoRoutingMode.combined,
        ),
        providerGeo: runtime,
      );
      final connecting = fixture.notifier.connect(_server());
      await runtime.resolving.future;
      await fixture.notifier.disconnect();
      gate.complete(null);
      await connecting;
      expect(fixture.state.status, ConnectionStatus.disconnected);
    },
  );

  for (final settings in [
    const AppSettings(geoRoutingMode: GeoRoutingMode.builtIn),
    const AppSettings(
      routingMode: RoutingMode.global,
      geoRoutingMode: GeoRoutingMode.provider,
    ),
  ]) {
    test(
      'no provider resolution for ${settings.routingMode.name}/${settings.geoRoutingMode.name}',
      () async {
        final runtime = _GeoRuntime(
          failure: const ProviderGeoException(ProviderGeoIssue.cache),
        );
        final source = _FakeSource();
        final fixture = await _fixture(
          [_FakeSource(), source],
          savedSettings: settings,
          providerGeo: runtime,
        );
        await fixture.notifier.connect(_server());
        expect(runtime.calls, 0);
        expect(source.providerRouting, isNull);
        expect(source.starts, 1);
      },
    );
  }

  for (final locale in ['ru', 'en']) {
    test(
      'invalid provider cache prevents native start with localized error ($locale)',
      () async {
        final runtime = _GeoRuntime(
          failure: const ProviderGeoException(ProviderGeoIssue.cache),
        );
        final probe = _FakeSource();
        final fixture = await _fixture(
          [probe],
          savedSettings: AppSettings(
            locale: locale,
            geoRoutingMode: GeoRoutingMode.provider,
          ),
          providerGeo: runtime,
        );
        await fixture.notifier.connect(_server());
        expect(fixture.state.status, ConnectionStatus.error);
        expect(
          fixture.state.errorMessage,
          S(locale).providerGeoFailure(ProviderGeoIssue.cache),
        );
        final nextLocale = locale == 'ru' ? 'en' : 'ru';
        await fixture.container
            .read(settingsProvider.notifier)
            .setLocale(nextLocale);
        await Future<void>.delayed(Duration.zero);
        expect(
          fixture.state.errorMessage,
          S(nextLocale).providerGeoFailure(ProviderGeoIssue.cache),
        );
        expect(fixture.state.status, ConnectionStatus.error);
        expect(runtime.calls, 1);
        expect(probe.statusReads, 1);
        expect(probe.starts, 0);
        expect(probe.stops, 0);
      },
    );
  }

  for (final locale in ['ru', 'en']) {
    for (final link in [
      'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@192.0.2.10:443?type=kcp#Node',
      'hy2://synthetic-private-password@192.0.2.10:443?pinSHA256=FAKE-FINGERPRINT',
    ]) {
      test(
        'unsupported ${link.split(':').first} options are explained safely ($locale)',
        () async {
          final probe = _FakeSource();
          final fixture = await _fixture([probe], locale: locale);
          await fixture.notifier.connect(_server(link: link));
          expect(fixture.state.status, ConnectionStatus.error);
          expect(
            fixture.state.errorMessage,
            S(locale).serverOptionsUnavailable,
          );
          expect(
            fixture.state.errorMessage,
            isNot(contains('synthetic-private')),
          );
          expect(probe.starts, 0);
        },
      );
    }

    test(
      'builder option guard does not reject the whole protocol ($locale)',
      () async {
        final failure = Completer<void>();
        final source = _FakeSource()..startResult = failure.future;
        final fixture = await _fixture([_FakeSource(), source], locale: locale);
        final connecting = fixture.notifier.connect(_server());
        await source.startRequested.future;
        failure.completeError(UnsupportedError('synthetic-private-key-field'));
        await connecting;
        expect(fixture.state.status, ConnectionStatus.error);
        expect(fixture.state.errorMessage, S(locale).serverOptionsUnavailable);
        expect(
          fixture.state.errorMessage,
          isNot(contains('synthetic-private')),
        );
        expect(source.disposed, isTrue);
      },
    );

    test(
      'Android transport failure keeps its owner until confirmed stop ($locale)',
      () async {
        final source = _FakeSource();
        final fixture = await _fixture([_FakeSource(), source], locale: locale);
        await fixture.notifier.connect(_server());
        source.emitStatus!(const VpnCoreStatus(state: 'CONNECTED'));
        source.emitError!(VpnDatasource.nativeStatusUnavailableMessage);
        expect(fixture.state.status, ConnectionStatus.error);
        expect(fixture.state.errorMessage, S(locale).vpnStatusUnavailable);
        expect(fixture.state.activeServer?.id, 1);
        expect(source.disposed, isFalse);
        final ack = Completer<void>();
        source.stopResult = ack.future;
        final stop = fixture.notifier.disconnect();
        await source.stopRequested.future;
        expect(fixture.state.status, ConnectionStatus.disconnecting);
        expect(source.disposed, isFalse);
        ack.complete();
        await stop;
        expect(fixture.state.status, ConnectionStatus.disconnected);
        expect(source.disposed, isTrue);
      },
    );

    test('NaiveProxy unavailability is explained in $locale', () async {
      final fixture = await _fixture([_FakeSource()], locale: locale);
      await fixture.notifier.connect(
        _server(link: 'naive+https://user:pass@example.com:443#Node'),
      );
      expect(fixture.state.status, ConnectionStatus.error);
      expect(
        fixture.state.errorMessage,
        S(locale).protocolUnavailable('NaiveProxy'),
      );
    });
  }

  for (final locale in ['ru', 'en']) {
    test(
      'failed native stop remains an error and cleanup can be retried ($locale)',
      () async {
        final source = _FakeSource();
        final fixture = await _fixture([_FakeSource(), source], locale: locale);
        await fixture.notifier.connect(_server());
        source.emitStatus!(const VpnCoreStatus(state: 'CONNECTED'));
        final failure = Completer<void>();
        source.stopResult = failure.future;
        final disconnecting = fixture.notifier.disconnect();
        await source.stopRequested.future;
        failure.completeError(StateError('native stop failed'));
        await disconnecting;
        expect(fixture.state.status, ConnectionStatus.error);
        expect(fixture.state.errorMessage, S(locale).vpnStopFailed);
        expect(fixture.state.activeServer?.id, 1);
        expect(source.disposed, isFalse);
        source.emitStatus!(const VpnCoreStatus(state: 'CONNECTED'));
        expect(fixture.state.status, ConnectionStatus.error);
        source.stopResult = null;
        await fixture.notifier.disconnect();
        expect(source.stops, 2);
        expect(source.disposed, isTrue);
        expect(fixture.state.status, ConnectionStatus.disconnected);
      },
    );

    test(
      'Apple unavailable initialization is not masked by a native stop ($locale)',
      () async {
        final source = _FakeSource()
          ..initializationError = const AppleVpnException(
            AppleVpnFailure.unavailable,
          );
        final fixture = await _fixture([_FakeSource(), source], locale: locale);
        await fixture.notifier.connect(_server());
        expect(fixture.state.status, ConnectionStatus.error);
        expect(fixture.state.errorMessage, S(locale).appleVpnUnavailable);
        expect(source.stops, 0);
        expect(source.disposed, isTrue);
      },
    );

    test(
      'Apple confirmed startup failure uses the localized explanation ($locale)',
      () async {
        final source = _FakeSource();
        final fixture = await _fixture([_FakeSource(), source], locale: locale);
        await fixture.notifier.connect(_server());
        source.emitError!(AppleVpnDatasource.connectionFailedMessage);
        expect(fixture.state.status, ConnectionStatus.error);
        expect(fixture.state.errorMessage, S(locale).appleVpnConnectFailed);
      },
    );
  }

  test(
    'a new connection waits for successful cleanup of the retained failed tunnel',
    () async {
      final previous = _FakeSource();
      final next = _FakeSource();
      final fixture = await _fixture([_FakeSource(), previous, next]);
      await fixture.notifier.connect(_server());
      previous.emitStatus!(const VpnCoreStatus(state: 'CONNECTED'));
      final failure = Completer<void>();
      previous.stopResult = failure.future;
      final switching = fixture.notifier.connect(_server(id: 2));
      await previous.stopRequested.future;
      failure.completeError(StateError('native stop failed'));
      await switching;
      expect(fixture.state.status, ConnectionStatus.error);
      expect(fixture.state.activeServer?.id, 1);
      expect(next.starts, 0);
      expect(previous.disposed, isFalse);
      previous.stopResult = null;
      await fixture.notifier.connect(_server(id: 2));
      expect(previous.stops, 2);
      expect(previous.disposed, isTrue);
      expect(next.starts, 1);
      expect(fixture.state.activeServer?.id, 2);
    },
  );

  test(
    'cleanup failure after provider disposal does not escape as an unhandled future',
    () async {
      final start = Completer<void>();
      final failure = Completer<void>();
      final source = _FakeSource()
        ..startResult = start.future
        ..stopResult = failure.future;
      final fixture = await _fixture([_FakeSource(), source]);
      final connecting = fixture.notifier.connect(_server());
      await source.startRequested.future;
      fixture.dispose();
      start.complete();
      await source.stopRequested.future;
      failure.completeError(StateError('native stop failed'));
      await connecting;
      await Future<void>.delayed(Duration.zero);
      expect(source.disposed, isTrue);
    },
  );

  test(
    'late events after a thrown start failure cannot revive the failed connection',
    () async {
      final failure = Completer<void>();
      final source = _FakeSource()..startResult = failure.future;
      final fixture = await _fixture([_FakeSource(), source]);
      final connecting = fixture.notifier.connect(_server());
      await source.startRequested.future;
      failure.completeError(StateError('native start failed'));
      await connecting;
      expect(fixture.state.status, ConnectionStatus.error);
      source.emitStatus!(const VpnCoreStatus(state: 'CONNECTED'));
      expect(fixture.state.status, ConnectionStatus.error);
      expect(source.disposed, isTrue);
    },
  );

  for (final link in [
    'tuic://a3482e88-686a-4a58-8126-99c9df64b7bf:pass@example.com:443?congestion_control=bbr#TUIC',
    'wireguard://example.com:51820?privateKey=private&publicKey=public&address=10.0.0.2%2F32#WG',
  ]) {
    test(
      '${link.split(':').first} is no longer rejected by a stale desktop guard',
      () async {
        final source = _FakeSource();
        final fixture = await _fixture([_FakeSource(), source]);
        await fixture.notifier.connect(_server(link: link));
        expect(source.starts, 1);
        expect(fixture.state.status, ConnectionStatus.connecting);
        expect(fixture.state.errorMessage, isNull);
      },
    );
  }
}
