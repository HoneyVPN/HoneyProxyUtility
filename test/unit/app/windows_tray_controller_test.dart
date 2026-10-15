import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:honeyproxyutility/app/windows_tray_controller.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/singbox_datasource.dart';
import 'package:honeyproxyutility/features/connection/data/windows/windows_session.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/vpn_core_status.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/models/subscription_model.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscription_order.dart';

class _Commands extends MethodChannel {
  _Commands() : super('test/honey/tray');
  Future<dynamic> Function(MethodCall)? handler;
  final calls = <MethodCall>[];
  Completer<void>? quitGate;
  bool failQuit = false;
  @override
  void setMethodCallHandler(Future<dynamic> Function(MethodCall)? value) {
    handler = value;
  }

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    calls.add(MethodCall(method, arguments));
    if (method == 'quit') {
      await quitGate?.future;
      if (failQuit) throw PlatformException(code: 'quit_unavailable');
    }
    return null;
  }

  Future<bool> action(
    String name, [
    Map<String, Object?> extra = const {},
  ]) async =>
      await handler!(MethodCall('trayAction', {'action': name, ...extra}))
          as bool;
  Map get state =>
      calls.lastWhere((c) => c.method == 'setTrayState').arguments as Map;
  int get quits => calls.where((c) => c.method == 'quit').length;
  String tokenForName(String name) =>
      (state['servers'] as List).cast<Map>().singleWhere(
            (row) => row['name'] == name,
          )['id']
          as String;
}

class _Subscriptions extends SubscriptionsNotifier {
  _Subscriptions([this.initial]);
  final List<SubscriptionModel>? initial;
  @override
  Future<SubscriptionsState> build() async => SubscriptionsState(
    subs:
        initial ??
        const [
          SubscriptionModel(
            id: 10,
            url: 'https://feed.example.invalid/PRIVATE-SUB-TOKEN',
            name: 'Plus',
          ),
        ],
  );

  @override
  Future<void> move(
    int id, {
    required String expectedUrl,
    int? beforeId,
    String? expectedBeforeUrl,
  }) async {
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(
        subs: moveSubscription(
          current.subs,
          id,
          expectedUrl: expectedUrl,
          beforeId: beforeId,
          expectedBeforeUrl: expectedBeforeUrl,
        ),
      ),
    );
  }
}

class _Factory {
  final sources = <_Source>[];
  final statusReads = <Future<VpnCoreStatus?>>[];
  final trace = <String>[];
  Completer<void>? stopGate;
  Completer<void>? startGate;
  bool failStop = false;
  _Source create({
    required void Function(VpnCoreStatus) onStatusChanged,
    void Function(String)? onError,
  }) {
    final source = _Source(this, onStatusChanged);
    sources.add(source);
    return source;
  }
}

class _SettingsWriteFailure extends InMemorySharedPreferencesStore {
  _SettingsWriteFailure(Map<String, Object> data, {required this.throwFailure})
    : super.withData(data);

  final bool throwFailure;
  var settingsWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await super.setValue(valueType, key, value);
    if (key == 'flutter.honeyvpn_settings' && ++settingsWrites == 1) {
      if (throwFailure)
        throw StateError('synthetic-private-preferences-detail');
      return false;
    }
    return true;
  }
}

class _Connection extends ConnectionNotifier {
  _Connection(this.factory);
  final _Factory factory;

  @override
  Future<void> connect(ServerProfileModel server) async {
    factory.trace.add(
      'connect:${server.id}:${ref.read(settingsProvider).value?.connectionMode.name}',
    );
    await super.connect(server);
  }
}

class _Source extends VpnDatasource {
  _Source(this.factory, this.emit)
    : super(onStatusChanged: emit, platform: VpnPlatform.unsupported);
  final _Factory factory;
  final void Function(VpnCoreStatus) emit;
  int profile = 0;
  @override
  bool get requiresNativeSessionDiscovery => false;
  @override
  Future<VpnCoreStatus?> readCurrentStatus() => factory.statusReads.isNotEmpty
      ? factory.statusReads.removeAt(0)
      : Future.value(const VpnCoreStatus(state: 'DISCONNECTED'));
  @override
  void bindProfile(int profileId) => profile = profileId;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> start(
    ParsedProxy proxy, {
    ConnectionMode mode = ConnectionMode.tunnel,
    AppSettings settings = const AppSettings(),
  }) async {
    factory.trace.add('start:$profile:${mode.name}');
    await factory.startGate?.future;
    emit(const VpnCoreStatus(state: 'CONNECTED'));
  }

  @override
  Future<void> stop() async {
    factory.trace.add('stop:$profile');
    await factory.stopGate?.future;
    if (factory.failStop) throw StateError('PRIVATE_NATIVE_ERROR');
    factory.trace.add('stopped:$profile');
  }

  @override
  void reattach() {}
  @override
  void dispose() {}
}

ServerProfileModel _profile(
  int id, {
  String? name,
  String subscriptionId = 'https://feed.example.invalid/PRIVATE-SUB-TOKEN',
  bool isFavorite = false,
}) => ServerProfileModel(
  id: id,
  protocol: 'vless',
  name: name ?? 'Server $id',
  host: 'PRIVATE-HOST.example.invalid',
  port: 443,
  configJson: jsonEncode({
    'rawLink':
        'vless://00000000-0000-4000-8000-000000000000@demo.example.invalid:443?security=none&type=tcp#PRIVATE-CONFIG',
  }),
  subscriptionId: subscriptionId,
  addedAt: DateTime.utc(2026),
  isSelected: id == 1,
  isFavorite: isFavorite,
);

class _Fixture {
  _Fixture(this.container, this.factory, this.channel, this.controller);
  final ProviderContainer container;
  final _Factory factory;
  final _Commands channel;
  final WindowsTrayController controller;
  final routes = <String>[];
  final errors = <String>[];
  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

Future<_Fixture> _fixture({
  _Factory? factory,
  bool disclosed = true,
  List<ServerProfileModel>? profiles,
  List<SubscriptionModel>? subscriptions,
  Future<ClipboardData?> Function()? clipboard,
}) async {
  SharedPreferences.setMockInitialValues({
    'honeyvpn_servers': ServerProfileModel.listToJson(
      profiles ?? [_profile(1), _profile(2)],
    ),
    'honeyvpn_settings': const AppSettings(locale: 'en').toJsonString(),
    'vpn_disclosure_accepted': disclosed,
  });
  final native = factory ?? _Factory();
  final container = ProviderContainer(
    overrides: [
      subscriptionsProvider.overrideWith(() => _Subscriptions(subscriptions)),
      connectionNotifierProvider.overrideWith(() => _Connection(native)),
      vpnDatasourceFactoryProvider.overrideWithValue(native.create),
    ],
  );
  final channel = _Commands();
  late _Fixture fixture;
  final controller = WindowsTrayController(
    container: container,
    channel: channel,
    navigate: (route) => fixture.routes.add(route),
    showError: (message) => fixture.errors.add(message),
    readClipboard: clipboard,
  );
  fixture = _Fixture(container, native, channel, controller);
  controller.start();
  addTearDown(() {
    controller.dispose();
    container.dispose();
  });
  await container.read(serversNotifierProvider.future);
  await container.read(settingsProvider.future);
  await fixture.settle();
  return fixture;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final locale in ['ru', 'en']) {
    for (final throwFailure in [false, true]) {
      test(
        '$locale tray mode ${throwFailure ? "throwing" : "false"} save fails safely after confirmed stop',
        () async {
          final fixture = await _fixture();
          final settings = fixture.container.read(settingsProvider.notifier);
          await settings.setLocale(locale);
          await fixture.channel.action('toggleConnection');
          await fixture.settle();
          expect(
            fixture.container.read(connectionNotifierProvider).isConnected,
            isTrue,
          );
          final startsBefore = fixture.factory.trace
              .where((event) => event.startsWith('start:'))
              .length;
          final store = _SettingsWriteFailure(
            await SharedPreferencesStorePlatform.instance.getAll(),
            throwFailure: throwFailure,
          );
          SharedPreferencesStorePlatform.instance = store;
          expect(
            await fixture.channel.action('setTunnel', {'tunnel': false}),
            isFalse,
          );
          await fixture.settle();
          expect(
            fixture.container.read(connectionNotifierProvider).status,
            ConnectionStatus.disconnected,
          );
          expect(
            fixture.container
                .read(settingsProvider)
                .requireValue
                .connectionMode,
            ConnectionMode.tunnel,
          );
          expect(fixture.factory.trace, contains('stopped:1'));
          expect(
            fixture.factory.trace.where((event) => event.startsWith('start:')),
            hasLength(startsBefore),
          );
          expect(
            store.settingsWrites,
            2,
          ); // Failed save plus one key-only restoration.
          expect(fixture.errors, [S(locale).settingsSaveFailed]);
          expect(fixture.errors.single, isNot(S(locale).vpnStopFailed));
          expect(fixture.errors.single, isNot(contains('synthetic-private')));
          final prefs = await SharedPreferences.getInstance();
          expect(
            AppSettings.fromJsonString(
              prefs.getString('honeyvpn_settings')!,
            ).connectionMode,
            ConnectionMode.tunnel,
          );
        },
      );
    }

    test(
      '$locale tray failed stop keeps the VPN-stop error and does not save the requested mode',
      () async {
        final fixture = await _fixture();
        await fixture.container
            .read(settingsProvider.notifier)
            .setLocale(locale);
        await fixture.channel.action('toggleConnection');
        fixture.factory.failStop = true;
        expect(
          await fixture.channel.action('setTunnel', {'tunnel': false}),
          isFalse,
        );
        await fixture.settle();
        expect(fixture.errors, [S(locale).vpnStopFailed]);
        expect(
          fixture.container.read(settingsProvider).requireValue.connectionMode,
          ConnectionMode.tunnel,
        );
        fixture.factory.failStop = false;
      },
    );
  }

  test(
    'tray metadata follows providers without exporting profile secrets',
    () async {
      final fixture = await _fixture(
        profiles: [
          _profile(1, name: '${List.filled(150, '🇳🇱').join()}\nNode'),
          _profile(2),
        ],
      );
      final state = fixture.channel.state;
      expect(state.keys.toSet(), {
        'locale',
        'connected',
        'busy',
        'selectedId',
        'selectedName',
        'tunnel',
        'servers',
        'canConnect',
      });
      final encoded = jsonEncode(state);
      for (final secret in [
        'PRIVATE-CONFIG',
        'PRIVATE-HOST',
        'PRIVATE-SUB-TOKEN',
        'rawLink',
        'configJson',
        'nativeSessionId',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      final first = (state['servers'] as List).first as Map;
      expect(first['group'], 'Plus');
      expect(
        utf8.encode(first['name'] as String).length,
        lessThanOrEqualTo(512),
      );
      expect(first['name'], isNot(contains('\n')));
      await fixture.container.read(settingsProvider.notifier).setLocale('ru');
      await fixture.settle();
      expect(fixture.channel.state['locale'], 'ru');
      expect(fixture.channel.state['canConnect'], true);
    },
  );

  test('tray flags use cleaned presentation names and country codes', () async {
    final fixture = await _fixture(
      profiles: [
        _profile(1, name: '🇫🇮 FI Finland'),
        _profile(2, name: '[NL] Netherlands'),
        _profile(3, name: 'Local server'),
      ],
    );
    final rows = (fixture.channel.state['servers'] as List).cast<Map>();
    expect(rows.map((row) => row['countryCode']), ['FI', 'NL', '']);
    expect(rows.map((row) => row['name']), [
      'Finland',
      'Netherlands',
      'Local server',
    ]);
    expect(fixture.channel.state['selectedName'], 'Finland');
    expect(
      rows.every(
        (row) => row.keys.toSet().containsAll({
          'id',
          'name',
          'group',
          'groupId',
          'countryCode',
        }),
      ),
      isTrue,
    );
  });

  test(
    'tray follows subscription order with distinct IDs for same names',
    () async {
      const first = 'https://feed.example.invalid/PRIVATE-SUB-TOKEN';
      const second = 'https://second.example.invalid/PRIVATE-TOKEN-B';
      final fixture = await _fixture(
        profiles: [
          _profile(1, name: 'FI Finland'),
          _profile(2, name: 'NL Netherlands', subscriptionId: second),
        ],
        subscriptions: const [
          SubscriptionModel(id: 10, url: first, name: 'HoneyVPN'),
          SubscriptionModel(id: 11, url: second, name: 'HoneyVPN'),
        ],
      );
      await fixture.container
          .read(subscriptionsProvider.notifier)
          .move(
            11,
            expectedUrl: second,
            beforeId: 10,
            expectedBeforeUrl: first,
          );
      await fixture.settle();
      final rows = (fixture.channel.state['servers'] as List).cast<Map>();
      expect(rows.map((row) => row['name']), ['Netherlands', 'Finland']);
      expect(rows.map((row) => row['group']), ['HoneyVPN', 'HoneyVPN']);
      expect(rows.map((row) => row['groupId']), [
        'subscription-11',
        'subscription-10',
      ]);
      expect(
        fixture.channel.state['selectedId'],
        fixture.channel.tokenForName('Finland'),
      );
      expect(
        jsonEncode(fixture.channel.state),
        isNot(contains('PRIVATE-TOKEN-B')),
      );
    },
  );

  test(
    'favorite tray group comes first with unique rows and unchanged flag metadata',
    () async {
      final fixture = await _fixture(
        profiles: [
          _profile(1, name: '🇫🇮 FI Finland'),
          _profile(2, name: '[NL] Netherlands', isFavorite: true),
          _profile(3, name: 'DE Germany', isFavorite: true),
          _profile(4, name: 'Manual', subscriptionId: ''),
        ],
      );
      final rows = (fixture.channel.state['servers'] as List).cast<Map>();
      expect(rows.map((row) => row['name']), [
        'Netherlands',
        'Germany',
        'Manual',
        'Finland',
      ]);
      expect(rows.map((row) => row['groupId']), [
        'favorites',
        'favorites',
        'manual',
        'subscription-10',
      ]);
      expect(rows.take(2).map((row) => row['group']), [
        'Favorites',
        'Favorites',
      ]);
      expect(rows.map((row) => row['countryCode']), ['NL', 'DE', '', 'FI']);
      expect(rows.map((row) => row['id']).toSet(), hasLength(4));
      expect(
        fixture.channel.state['selectedId'],
        fixture.channel.tokenForName('Finland'),
      );
      for (final secret in [
        'PRIVATE-SUB-TOKEN',
        'PRIVATE-HOST',
        'PRIVATE-CONFIG',
      ]) {
        expect(jsonEncode(fixture.channel.state), isNot(contains(secret)));
      }
      await fixture.container.read(settingsProvider.notifier).setLocale('ru');
      await fixture.settle();
      final russianRows = (fixture.channel.state['servers'] as List)
          .cast<Map>();
      expect(russianRows.take(2).map((row) => row['group']), [
        'Избранное',
        'Избранное',
      ]);
      expect(russianRows.map((row) => row['countryCode']), [
        'NL',
        'DE',
        '',
        'FI',
      ]);
    },
  );

  test('favorite tray rows follow persisted subscription order', () async {
    const first = 'https://feed.example.invalid/PRIVATE-SUB-TOKEN';
    const second = 'https://second.example.invalid/PRIVATE-FAVORITE-TOKEN';
    final fixture = await _fixture(
      profiles: [
        _profile(1, name: 'FI Finland', isFavorite: true),
        _profile(
          2,
          name: 'NL Netherlands',
          subscriptionId: second,
          isFavorite: true,
        ),
        _profile(3, name: 'DE Germany'),
        _profile(4, name: 'FR France', subscriptionId: second),
      ],
      subscriptions: const [
        SubscriptionModel(id: 10, url: first, name: 'First'),
        SubscriptionModel(id: 11, url: second, name: 'Second'),
      ],
    );
    final favoriteToken = fixture.channel.tokenForName('Finland');
    await fixture.container
        .read(subscriptionsProvider.notifier)
        .move(11, expectedUrl: second, beforeId: 10, expectedBeforeUrl: first);
    await fixture.settle();
    final rows = (fixture.channel.state['servers'] as List).cast<Map>();
    expect(rows.map((row) => row['name']), [
      'Netherlands',
      'Finland',
      'France',
      'Germany',
    ]);
    expect(rows.map((row) => row['groupId']), [
      'favorites',
      'favorites',
      'subscription-11',
      'subscription-10',
    ]);
    expect(fixture.channel.tokenForName('Finland'), favoriteToken);
    expect(fixture.channel.state['selectedId'], favoriteToken);
  });

  test(
    'favorite mutation keeps selection and token, removal restores the provider group',
    () async {
      final fixture = await _fixture(
        profiles: [
          _profile(1, name: 'FI Finland'),
          _profile(2, name: 'NL Netherlands'),
        ],
      );
      final selectedToken = fixture.channel.tokenForName('Finland');
      final token = fixture.channel.tokenForName('Netherlands');
      final notifier = fixture.container.read(serversNotifierProvider.notifier);
      final profile = fixture.container
          .read(serversNotifierProvider)
          .requireValue
          .singleWhere((profile) => profile.id == 2);
      expect(await notifier.setFavoriteIfCurrent(profile, true), true);
      await fixture.settle();
      var rows = (fixture.channel.state['servers'] as List).cast<Map>();
      expect(rows.first['id'], token);
      expect(rows.first['groupId'], 'favorites');
      expect(rows.first['countryCode'], 'NL');
      expect(fixture.channel.state['selectedId'], selectedToken);
      expect(fixture.container.read(selectedServerProvider)?.id, 1);
      expect(fixture.factory.trace, isEmpty);
      expect(await notifier.setFavoriteIfCurrent(profile, false), true);
      await fixture.settle();
      rows = (fixture.channel.state['servers'] as List).cast<Map>();
      expect(rows.map((row) => row['name']), ['Finland', 'Netherlands']);
      expect(rows.every((row) => row['groupId'] == 'subscription-10'), true);
      expect(fixture.channel.tokenForName('Netherlands'), token);
      expect(fixture.channel.state['selectedId'], selectedToken);
      expect(fixture.factory.trace, isEmpty);
    },
  );

  test(
    'favorite tray rows have limit priority and retain an out-of-limit selection',
    () async {
      final fixture = await _fixture(
        profiles: [
          for (var id = 1; id <= 1026; id++)
            _profile(
              id,
              isFavorite: id == 1025,
            ).copyWith(isSelected: id == 1026),
        ],
      );
      final rows = (fixture.channel.state['servers'] as List).cast<Map>();
      expect(rows, hasLength(1024));
      expect(rows.first['name'], 'Server 1025');
      expect(rows.first['groupId'], 'favorites');
      expect(rows.last['name'], 'Server 1026');
      expect(rows.last['groupId'], 'subscription-10');
      expect(fixture.channel.state['selectedId'], rows.last['id']);
      expect(rows.map((row) => row['id']).toSet(), hasLength(1024));
      expect(rows.any((row) => row['name'] == 'Server 1023'), false);
      expect(rows.any((row) => row['name'] == 'Server 1024'), false);
    },
  );

  test(
    'favorite tray group keeps overflow within the native group limit',
    () async {
      final fixture = await _fixture(
        profiles: [
          for (var id = 1; id <= 131; id++)
            _profile(
              id,
              subscriptionId:
                  'https://group-$id.example.invalid/PRIVATE-GROUP-TOKEN',
              isFavorite: id == 131,
            ),
        ],
        subscriptions: [
          for (var id = 1; id <= 131; id++)
            SubscriptionModel(
              id: id,
              url: 'https://group-$id.example.invalid/PRIVATE-GROUP-TOKEN',
              name: 'HoneyVPN',
            ),
        ],
      );
      final rows = (fixture.channel.state['servers'] as List).cast<Map>();
      expect(rows.first['groupId'], 'favorites');
      expect(rows.map((row) => row['groupId']).toSet(), hasLength(128));
      expect(rows[126]['groupId'], 'subscription-126');
      expect(rows[127]['groupId'], 'other');
      expect(rows.last['groupId'], 'other');
      expect(
        jsonEncode(fixture.channel.state),
        isNot(contains('PRIVATE-GROUP-TOKEN')),
      );
    },
  );

  test(
    'stale tray token cannot select a replacement with the same stored ID',
    () async {
      final fixture = await _fixture();
      final oldToken = fixture.channel.tokenForName('Server 2');
      final notifier = fixture.container.read(serversNotifierProvider.notifier);
      await notifier.delete(2);
      await notifier.addFromProxy(
        const LinkDispatcher().dispatch(
          'vless://00000000-0000-4000-8000-000000000001@replacement.example.invalid:443?security=none#Replacement',
        ),
      );
      await fixture.settle();
      final replacement = fixture.container
          .read(serversNotifierProvider)
          .requireValue
          .singleWhere((profile) => profile.name == 'Replacement');
      expect(replacement.id, 2);
      expect(fixture.channel.tokenForName('Replacement'), isNot(oldToken));
      expect(
        await fixture.channel.action('selectServer', {'serverId': oldToken}),
        false,
      );
      expect(fixture.container.read(selectedServerProvider)?.id, 1);
      expect(fixture.factory.trace, isEmpty);
    },
  );

  test('tray binding is rechecked after native readiness awaits', () async {
    final discovery = Completer<VpnCoreStatus?>();
    final factory = _Factory()..statusReads.add(discovery.future);
    final fixture = await _fixture(factory: factory);
    final oldToken = fixture.channel.tokenForName('Server 2');
    final selecting = fixture.channel.action('selectServer', {
      'serverId': oldToken,
    });
    await fixture.settle();
    final notifier = fixture.container.read(serversNotifierProvider.notifier);
    await notifier.delete(2);
    await notifier.addFromProxy(
      const LinkDispatcher().dispatch(
        'vless://00000000-0000-4000-8000-000000000001@replacement.example.invalid:443?security=none#Replacement',
      ),
    );
    discovery.complete(const VpnCoreStatus(state: 'DISCONNECTED'));
    expect(await selecting, false);
    expect(fixture.container.read(selectedServerProvider)?.id, 1);
    expect(fixture.factory.trace, isEmpty);
  });

  test(
    'latency and selection updates retain tokens, configuration changes retire them',
    () async {
      final fixture = await _fixture();
      final token = fixture.channel.tokenForName('Server 2');
      final notifier = fixture.container.read(serversNotifierProvider.notifier);
      await notifier.updateLatency(2, 23);
      await fixture.settle();
      expect(fixture.channel.tokenForName('Server 2'), token);
      final profile = fixture.container
          .read(serversNotifierProvider)
          .requireValue
          .singleWhere((profile) => profile.id == 2);
      await notifier.selectServer(profile);
      await fixture.settle();
      expect(fixture.channel.tokenForName('Server 2'), token);
      await notifier.replaceSubscription(profile.subscriptionId, [
        const LinkDispatcher().dispatch(
          'vless://00000000-0000-4000-8000-000000000002@changed.example.invalid:443?security=none#Changed%20configuration',
        ),
      ]);
      await fixture.settle();
      expect(
        (fixture.channel.state['servers'] as List).cast<Map>().any(
          (row) => row['id'] == token,
        ),
        isFalse,
      );
      expect(
        await fixture.channel.action('selectServer', {'serverId': token}),
        false,
      );
    },
  );

  test(
    'selection mutation rejects a queued replacement instead of following reused ID',
    () async {
      final fixture = await _fixture();
      final notifier = fixture.container.read(serversNotifierProvider.notifier);
      final old = fixture.container
          .read(serversNotifierProvider)
          .requireValue
          .singleWhere((profile) => profile.id == 2);
      final deleting = notifier.delete(2);
      final adding = notifier.addFromProxy(
        const LinkDispatcher().dispatch(
          'vless://00000000-0000-4000-8000-000000000001@replacement.example.invalid:443?security=none#Replacement',
        ),
      );
      final selecting = notifier.selectServerIfCurrent(old);
      await deleting;
      await adding;
      expect(await selecting, false);
      expect(fixture.container.read(selectedServerProvider)?.id, 1);
      expect(
        fixture.container
            .read(serversNotifierProvider)
            .requireValue
            .singleWhere((profile) => profile.name == 'Replacement')
            .id,
        old.id,
      );
    },
  );

  test(
    'tray retains an out-of-limit selection in its original group order',
    () async {
      const second = 'https://second.example.invalid/PRIVATE-CAP-TOKEN';
      final fixture = await _fixture(
        profiles: [
          for (var id = 1; id <= 1025; id++)
            _profile(
              id,
              subscriptionId: id <= 1024
                  ? 'https://feed.example.invalid/PRIVATE-SUB-TOKEN'
                  : second,
            ).copyWith(isSelected: id == 1025),
        ],
        subscriptions: const [
          SubscriptionModel(
            id: 10,
            url: 'https://feed.example.invalid/PRIVATE-SUB-TOKEN',
            name: 'First',
          ),
          SubscriptionModel(id: 11, url: second, name: 'Second'),
        ],
      );
      final rows = (fixture.channel.state['servers'] as List).cast<Map>();
      expect(rows, hasLength(1024));
      expect(rows.first['name'], 'Server 1');
      expect(rows.first['group'], 'First');
      expect(rows.last['name'], 'Server 1025');
      expect(rows.last['group'], 'Second');
      expect(rows.any((row) => row['name'] == 'Server 1024'), false);
      expect(fixture.channel.state['selectedId'], rows.last['id']);
    },
  );

  test(
    'same-named overflow groups stay within the native group limit',
    () async {
      final fixture = await _fixture(
        profiles: [
          for (var id = 1; id <= 130; id++)
            _profile(
              id,
              subscriptionId:
                  'https://group-$id.example.invalid/PRIVATE-GROUP-TOKEN',
            ),
        ],
        subscriptions: [
          for (var id = 1; id <= 130; id++)
            SubscriptionModel(
              id: id,
              url: 'https://group-$id.example.invalid/PRIVATE-GROUP-TOKEN',
              name: 'HoneyVPN',
            ),
        ],
      );
      final rows = (fixture.channel.state['servers'] as List).cast<Map>();
      expect(rows.map((row) => row['groupId']).toSet(), hasLength(128));
      expect(rows[126]['groupId'], 'subscription-127');
      expect(rows[127]['groupId'], 'other');
      expect(rows.last['groupId'], 'other');
      expect(
        jsonEncode(fixture.channel.state),
        isNot(contains('PRIVATE-GROUP-TOKEN')),
      );
    },
  );

  test(
    'native-rejected C1 and line-separator labels normalize without losing state',
    () async {
      final fixture = await _fixture(
        profiles: [_profile(1, name: 'Node\u0080\u009f\u2028\u2029End')],
      );
      final name = fixture.channel.state['selectedName'] as String;
      expect(name, 'Node    End');
      expect(RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(name), false);
      expect(fixture.channel.state['canConnect'], true);
    },
  );

  test(
    'tray mutation waits for native startup discovery instead of guessed idle',
    () async {
      final discovery = Completer<VpnCoreStatus?>();
      final factory = _Factory()..statusReads.add(discovery.future);
      final fixture = await _fixture(factory: factory);
      expect(fixture.channel.state['busy'], true);
      expect(fixture.channel.state['canConnect'], false);
      final selecting = fixture.channel.action('selectServer', {
        'serverId': fixture.channel.tokenForName('Server 2'),
      });
      await fixture.settle();
      expect(fixture.container.read(selectedServerProvider)?.id, 1);
      expect(factory.trace, isEmpty);
      discovery.complete(const VpnCoreStatus(state: 'DISCONNECTED'));
      expect(await selecting, true);
      expect(fixture.container.read(selectedServerProvider)?.id, 2);
    },
  );

  test(
    'duplicate connect and stale mutation commands are ignored while busy',
    () async {
      final factory = _Factory()..startGate = Completer<void>();
      final fixture = await _fixture(factory: factory);
      final connecting = fixture.channel.action('toggleConnection');
      await fixture.settle();
      expect(await fixture.channel.action('toggleConnection'), false);
      expect(
        await fixture.channel.action('selectServer', {
          'serverId': fixture.channel.tokenForName('Server 2'),
        }),
        false,
      );
      expect(
        factory.trace.where((event) => event.startsWith('start:')),
        hasLength(1),
      );
      factory.startGate!.complete();
      await connecting;
      expect(
        fixture.container.read(connectionNotifierProvider).isConnected,
        true,
      );
    },
  );

  test(
    'connected server and mode switches wait for stop ACK before reconnect',
    () async {
      final fixture = await _fixture();
      await fixture.channel.action('toggleConnection');
      fixture.factory.stopGate = Completer<void>();
      final switching = fixture.channel.action('selectServer', {
        'serverId': fixture.channel.tokenForName('Server 2'),
      });
      await fixture.settle();
      expect(fixture.container.read(selectedServerProvider)?.id, 1);
      expect(fixture.factory.trace, isNot(contains('start:2:tunnel')));
      fixture.factory.stopGate!.complete();
      await switching;
      expect(fixture.container.read(selectedServerProvider)?.id, 2);
      expect(
        fixture.factory.trace.indexOf('stopped:1'),
        lessThan(fixture.factory.trace.indexOf('start:2:tunnel')),
      );
      fixture.factory.stopGate = null;
      await fixture.channel.action('setTunnel', {'tunnel': false});
      expect(
        fixture.container.read(settingsProvider).value!.connectionMode,
        ConnectionMode.proxy,
      );
      // This suite runs on Mac too: the real notifier correctly rejects Apple
      // Proxy mode there. The tray must still request the same selected profile
      // after the mode is saved; the Windows native build exercises its core.
      expect(fixture.factory.trace, contains('connect:2:proxy'));
      expect(
        fixture.factory.trace.lastIndexOf('stopped:2'),
        lessThan(fixture.factory.trace.indexOf('connect:2:proxy')),
      );
    },
  );

  test('quit during connect waits for startup and actual child stop', () async {
    final factory = _Factory()
      ..startGate = Completer<void>()
      ..stopGate = Completer<void>();
    final fixture = await _fixture(factory: factory);
    final connecting = fixture.channel.action('toggleConnection');
    await fixture.settle();
    final quitting = fixture.channel.action('quit');
    expect(await fixture.channel.action('quit'), false);
    await fixture.settle();
    expect(fixture.channel.quits, 0);
    factory.startGate!.complete();
    await fixture.settle();
    expect(factory.trace, contains('stop:1'));
    expect(fixture.channel.quits, 0);
    factory.stopGate!.complete();
    expect(await quitting, true);
    await connecting;
    expect(fixture.channel.quits, 1);
    expect(
      fixture.container.read(connectionNotifierProvider).status,
      ConnectionStatus.disconnected,
    );
  });

  test('initial disconnected UI cannot quit before native discovery', () async {
    final discovery = Completer<VpnCoreStatus?>();
    final factory = _Factory()..statusReads.add(discovery.future);
    final fixture = await _fixture(factory: factory);
    expect(
      fixture.container.read(connectionNotifierProvider).status,
      ConnectionStatus.disconnected,
    );
    final quitting = fixture.channel.action('quit');
    await fixture.settle();
    expect(fixture.channel.quits, 0);
    discovery.complete(const VpnCoreStatus(state: 'DISCONNECTED'));
    expect(await quitting, true);
    expect(fixture.channel.quits, 1);
  });

  test('startup recovery error allows closing only the unowned UI', () async {
    final discovery = Completer<VpnCoreStatus?>();
    final factory = _Factory()..statusReads.add(discovery.future);
    final fixture = await _fixture(factory: factory);
    discovery.completeError(
      const WindowsSessionException(WindowsSessionFailure.recoveryRequired),
    );
    await fixture.settle();
    expect(
      fixture.container.read(connectionNotifierProvider).status,
      ConnectionStatus.error,
    );
    expect(await fixture.channel.action('quit'), true);
    expect(fixture.channel.quits, 1);
    expect(factory.trace.where((event) => event.startsWith('stop:')), isEmpty);
    expect(factory.trace.where((event) => event.startsWith('start:')), isEmpty);
    // Exiting this failed new window never invents a disconnected VPN state.
    expect(
      fixture.container.read(connectionNotifierProvider).status,
      ConnectionStatus.error,
    );
  });

  test(
    'a managed session still requires idle proof after recovery fails',
    () async {
      final fixture = await _fixture();
      await fixture.channel.action('toggleConnection');
      final discovery = Completer<VpnCoreStatus?>();
      fixture.factory.statusReads.add(discovery.future);
      final quitting = fixture.channel.action('quit');
      await fixture.settle();
      discovery.completeError(
        const WindowsSessionException(WindowsSessionFailure.recoveryRequired),
      );
      expect(await quitting, false);
      expect(fixture.channel.quits, 0);
      expect(fixture.factory.trace, contains('stopped:1'));
      expect(
        fixture.container.read(connectionNotifierProvider).status,
        ConnectionStatus.error,
      );
    },
  );

  test(
    'quit cancels a pending server switch without saving or reconnecting',
    () async {
      final fixture = await _fixture();
      await fixture.channel.action('toggleConnection');
      fixture.factory.stopGate = Completer<void>();
      final selecting = fixture.channel.action('selectServer', {
        'serverId': fixture.channel.tokenForName('Server 2'),
      });
      await fixture.settle();
      final quitting = fixture.channel.action('quit');
      await fixture.settle();
      expect(fixture.channel.quits, 0);
      fixture.factory.stopGate!.complete();
      expect(await quitting, true);
      expect(await selecting, false);
      expect(fixture.container.read(selectedServerProvider)?.id, 1);
      expect(fixture.factory.trace, isNot(contains('connect:2:tunnel')));
      expect(fixture.channel.quits, 1);
    },
  );

  test(
    'native quit holds the Home connection gate until window exit',
    () async {
      final fixture = await _fixture();
      fixture.channel.quitGate = Completer<void>();
      final quitting = fixture.channel.action('quit');
      await fixture.settle();
      expect(fixture.channel.quits, 1);
      await fixture.container
          .read(connectionNotifierProvider.notifier)
          .connect(_profile(1));
      expect(
        fixture.factory.trace.where((e) => e.startsWith('start:')),
        isEmpty,
      );
      fixture.channel.quitGate!.complete();
      expect(await quitting, true);
      await fixture.container
          .read(connectionNotifierProvider.notifier)
          .connect(_profile(1));
      expect(
        fixture.factory.trace.where((e) => e.startsWith('start:')),
        isEmpty,
      );
    },
  );

  test('rejected native quit releases the Home connection gate', () async {
    final fixture = await _fixture();
    fixture.channel.quitGate = Completer<void>();
    fixture.channel.failQuit = true;
    final quitting = fixture.channel.action('quit');
    await fixture.settle();
    await fixture.container
        .read(connectionNotifierProvider.notifier)
        .connect(_profile(1));
    expect(fixture.factory.trace.where((e) => e.startsWith('start:')), isEmpty);
    fixture.channel.quitGate!.complete();
    expect(await quitting, false);
    await fixture.container
        .read(connectionNotifierProvider.notifier)
        .connect(_profile(1));
    expect(fixture.factory.trace, contains('start:1:tunnel'));
  });

  test('unknown native idle or stop failure never sends native quit', () async {
    final fixture = await _fixture();
    fixture.factory.statusReads.add(Future.value(null));
    expect(await fixture.channel.action('quit'), false);
    expect(fixture.channel.quits, 0);
    expect(fixture.errors, hasLength(1));
    await fixture.channel.action('toggleConnection');
    fixture.factory.failStop = true;
    expect(await fixture.channel.action('quit'), false);
    expect(fixture.channel.quits, 0);
    expect(
      fixture.container.read(connectionNotifierProvider).status,
      ConnectionStatus.error,
    );
    expect(fixture.routes.last, '/');
    expect(fixture.errors.last, isNot(contains('PRIVATE_NATIVE_ERROR')));
    fixture.factory.failStop = false;
  });

  test(
    'clipboard opens existing import preview with fresh activation, never saves',
    () async {
      const source = 'https://feed.example.invalid/PRIVATE-TOKEN?q=a+b#frag';
      var reads = 0;
      final fixture = await _fixture(
        clipboard: () async {
          reads++;
          return const ClipboardData(text: source);
        },
      );
      expect(reads, 0);
      for (var i = 0; i < 2; i++) {
        expect(await fixture.channel.action('importClipboard'), true);
      }
      expect(reads, 2);
      final first = Uri.parse(fixture.routes[0]);
      final second = Uri.parse(fixture.routes[1]);
      expect(first.path, '/converter');
      expect(first.queryParameters['initialText'], source);
      expect(
        first.queryParameters['importActivation'],
        isNot(second.queryParameters['importActivation']),
      );
      expect(
        fixture.container.read(serversNotifierProvider).value,
        hasLength(2),
      );
      expect(
        fixture.factory.trace.where((e) => e.startsWith('start:')),
        isEmpty,
      );
      expect(
        jsonEncode(fixture.channel.state),
        isNot(contains('PRIVATE-TOKEN')),
      );
    },
  );

  test(
    'first-use disclosure and malformed action envelopes cannot start VPN',
    () async {
      final fixture = await _fixture(disclosed: false);
      expect(fixture.channel.state['canConnect'], false);
      expect(await fixture.channel.action('toggleConnection'), false);
      expect(fixture.routes.last, '/');
      for (final arguments in [
        {'action': 'selectServer', 'serverId': 2},
        {'action': 'selectServer', 'serverId': 'missing'},
        {'action': 'setTunnel', 'tunnel': 'false'},
        {'action': 'quit', 'token': 'PRIVATE'},
        {'action': 'unknown'},
      ]) {
        expect(
          await fixture.channel.handler!(MethodCall('trayAction', arguments)),
          false,
        );
      }
      expect(fixture.factory.trace, isEmpty);
      expect(fixture.channel.quits, 0);
      fixture.controller.dispose();
      expect(fixture.channel.handler, isNull);
    },
  );
}
