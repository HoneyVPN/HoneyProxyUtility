import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/apple_vpn_datasource.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/singbox_datasource.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/vpn_core_status.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

const _proxy = ShadowsocksConfig(
  name: 'Synthetic',
  host: '192.0.2.10',
  port: 8388,
  method: 'chacha20-ietf-poly1305',
  password: 'synthetic-secret',
  plugin: '',
  pluginOpts: '',
);
const _channel = MethodChannel('ru.honeyvpn.proxy/apple_vpn');
const _sessionA = '11111111-1111-4111-8111-111111111111';
const _sessionB = '22222222-2222-4222-8222-222222222222';

Map<String, dynamic> _event(
  String event, {
  Map<String, dynamic> values = const {},
}) => {
  'version': 1,
  'event': event,
  'coreReady': true,
  'running': event == 'started' || event == 'stats',
  if (event != 'stopped') 'profileId': 1,
  if (event != 'stopped') 'sessionId': _sessionA,
  'duration': 0,
  'trafficAvailable': false,
  'ratesAvailable': false,
  ...values,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  final statuses = <VpnCoreStatus>[];
  final errors = <String>[];
  late StreamController<dynamic> events;
  late AppleVpnDatasource source;
  bool available = true;
  bool running = false;
  Map<String, dynamic>? snapshot;

  setUp(() {
    available = true;
    running = false;
    snapshot = null;
    calls.clear();
    statuses.clear();
    errors.clear();
    events = StreamController<dynamic>.broadcast(sync: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'initialize' => available,
            'checkStatus' => running,
            'getStatus' => snapshot ?? _event(running ? 'started' : 'stopped'),
            'requestPermission' => true,
            _ => null,
          };
        });
    source = AppleVpnDatasource(
      onStatusChanged: statuses.add,
      onError: errors.add,
      statusEvents: events.stream,
      prepareGeo: () async => {},
      createSessionId: () => _sessionA,
    );
  });

  tearDown(() async {
    source.dispose();
    await events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('host-only build never requests permission or starts a VPN', () async {
    available = false;
    await expectLater(
      source.requestPermission(),
      throwsA(isA<AppleVpnException>()),
    );
    expect(calls.map((c) => c.method), ['initialize']);
    expect(statuses, isEmpty);
  });

  test(
    'missing native bridge fails safely, with no Windows fallback',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      final wrapper = VpnDatasource(
        onStatusChanged: statuses.add,
        platform: VpnPlatform.apple,
      );
      try {
        await expectLater(
          wrapper.initialize(),
          throwsA(isA<AppleVpnException>()),
        );
        expect(await wrapper.checkRunning(), isFalse);
        expect(statuses, isEmpty);
      } finally {
        wrapper.dispose();
      }
    },
  );

  test('unsupported desktop cannot start a Windows executable', () async {
    final wrapper = VpnDatasource(
      onStatusChanged: statuses.add,
      platform: VpnPlatform.unsupported,
    );
    await expectLater(wrapper.initialize(), throwsUnsupportedError);
    expect(await wrapper.checkRunning(), isFalse);
    wrapper.dispose();
  });

  test('system proxy mode is rejected before any native action', () async {
    await expectLater(
      source.start(_proxy, mode: ConnectionMode.proxy),
      throwsA(isA<AppleVpnException>()),
    );
    expect(calls, isEmpty);
  });

  test(
    'a stored system proxy preference is rejected before initialization',
    () async {
      await expectLater(
        source.start(
          _proxy,
          settings: const AppSettings(connectionMode: ConnectionMode.proxy),
        ),
        throwsA(isA<AppleVpnException>()),
      );
      expect(calls, isEmpty);
    },
  );

  test('submitting start does not report connected before NE status', () async {
    await source.initialize();
    expect(await source.requestPermission(), isTrue);
    await source.start(
      _proxy,
      profileId: 1,
      settings: const AppSettings(routingMode: RoutingMode.global),
    );
    expect(statuses, isEmpty);
    final call = calls.singleWhere((c) => c.method == 'start');
    final config =
        jsonDecode((call.arguments as Map)['config'] as String) as Map;
    expect((config['inbounds'] as List).first['type'], 'tun');
    expect((call.arguments as Map)['profileId'], 1);
    expect((call.arguments as Map)['sessionId'], _sessionA);
    events.add(_event('connecting'));
    events.add(_event('started'));
    expect(statuses.map((s) => s.state), ['CONNECTING', 'CONNECTED']);
  });

  test('reattach restores NE events without creating a new profile', () async {
    running = true;
    expect(await source.checkRunning(), isTrue);
    source.reattach();
    source.reattach();
    events.add(
      _event(
        'stats',
        values: {
          'uplink': 42,
          'downlink': 84,
          'uplinkTotal': 120,
          'downlinkTotal': 240,
          'duration': 3661,
          'trafficAvailable': true,
          'ratesAvailable': true,
        },
      ),
    );
    expect(statuses, hasLength(1));
    expect(statuses.single.duration, '01:01:01');
    expect(statuses.single.uploadSpeed, 42);
    expect(statuses.single.download, 240);
    expect(statuses.single.profileId, 1);
    expect(statuses.single.sessionId, _sessionA);
    expect(statuses.single.trafficAvailable, isTrue);
    expect(statuses.single.ratesAvailable, isTrue);
    expect(calls.map((c) => c.method), ['getStatus']);
  });

  test(
    'malformed counters and stale events after failure are harmless',
    () async {
      source.reattach();
      events.add('invalid');
      events.add(
        _event(
          'stats',
          values: {
            'uplink': 'invalid',
            'downlink': -10,
            'uplinkTotal': double.infinity,
            'duration': -100,
            'trafficAvailable': true,
            'ratesAvailable': true,
          },
        ),
      );
      expect(statuses.single.uploadSpeed, 0);
      expect(statuses.single.downloadSpeed, 0);
      expect(statuses.single.upload, 0);
      expect(statuses.single.duration, '00:00:00');
      expect(statuses.single.trafficAvailable, isFalse);
      expect(statuses.single.ratesAvailable, isFalse);
      events.add(_event('error', values: {'message': 'Tunnel failed'}));
      events.add(_event('started'));
      events.add(_event('stats', values: {'duration': 1}));
      expect(errors, ['Tunnel failed']);
      expect(statuses, hasLength(1));
    },
  );

  test('stop detaches stats even when native stop fails', () async {
    source.reattach();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async {
          throw PlatformException(code: 'STOP_FAILED');
        });
    await expectLater(source.stop(), throwsA(isA<PlatformException>()));
    events.add(_event('started'));
    expect(statuses, isEmpty);
  });

  test(
    'initial stopped snapshot is harmless, but confirmed startup failure reports an error',
    () async {
      await source.initialize();
      await source.start(_proxy, profileId: 1);
      events.add(_event('stopped'));
      expect(errors, isEmpty);
      statuses.clear();
      events.add(_event('connecting'));
      events.add(_event('stopped'));
      events.add(_event('started'));
      expect(errors, [AppleVpnDatasource.connectionFailedMessage]);
      expect(statuses.map((s) => s.state), ['CONNECTING']);
    },
  );

  test(
    'user stop during startup does not report a connection failure',
    () async {
      await source.initialize();
      await source.start(_proxy, profileId: 1);
      events.add(_event('connecting'));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'stop') events.add(_event('stopped'));
            return null;
          });
      await source.stop();
      expect(errors, isEmpty);
    },
  );

  test(
    'native discovery remains read-only when new starts are unavailable',
    () async {
      available = false;
      snapshot = _event(
        'started',
        values: {
          'coreReady': false,
          'profileId': 42,
          'sessionId': _sessionB,
          'duration': 1726,
        },
      );
      final status = await source.getStatus();
      expect(status?.state, 'CONNECTED');
      expect(status?.usesNativeSessionIdentity, isTrue);
      expect(status?.profileId, 42);
      expect(status?.sessionId, _sessionB);
      expect(status?.duration, '00:28:46');
      expect(status?.trafficAvailable, isFalse);
      expect(status?.ratesAvailable, isFalse);
      expect(calls.map((call) => call.method), ['getStatus']);
      expect(statuses, isEmpty);
    },
  );

  test(
    'unbound or invalid identity is rejected before a native start',
    () async {
      await expectLater(source.start(_proxy), throwsArgumentError);
      await expectLater(
        source.start(_proxy, profileId: 0),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'sanitized native host snapshot preserves running identity and byte units',
    () async {
      // AppleVpnStatusSnapshot.decode sanitizes the provider reply; the host
      // adds event=started/stats. Keep this wire fixture independent of _event.
      const hostSnapshot = <String, dynamic>{
        'version': 1,
        'event': 'started',
        'coreReady': true,
        'running': true,
        'sessionId': 'ABCDEF12-ABCD-4ABC-8ABC-ABCDEF123456',
        'profileId': 42,
        'duration': 1726,
        'trafficAvailable': true,
        'ratesAvailable': true,
        'uplinkTotal': 9000000000,
        'downlinkTotal': 12000000000,
        'uplink': 125,
        'downlink': 250,
      };
      snapshot = hostSnapshot;
      final restored = await source.getStatus();
      expect(restored?.state, 'CONNECTED');
      expect(restored?.profileId, 42);
      expect(restored?.sessionId, 'abcdef12-abcd-4abc-8abc-abcdef123456');
      expect(restored?.duration, '00:28:46');
      expect(restored?.upload, 9000000000);
      expect(restored?.download, 12000000000);
      expect(restored?.uploadSpeed, 125);
      expect(restored?.downloadSpeed, 250);
      expect(restored?.ratesAvailable, isTrue);
      source.reattach();
      events.add({...hostSnapshot, 'event': 'stats'});
      expect(statuses.single.state, 'CONNECTED');
      expect(statuses.single.profileId, 42);
      expect(statuses.single.downloadSpeed, 250);
      expect(calls.map((call) => call.method), ['getStatus']);
    },
  );

  test(
    'unknown versions and malformed identity do not invent a saved profile',
    () async {
      snapshot = _event('started', values: {'version': 2});
      expect(await source.getStatus(), isNull);
      snapshot = _event('started', values: {'profileId': '42'});
      expect((await source.getStatus())?.profileId, isNull);
      snapshot = _event('started', values: {'sessionId': 'malformed'});
      final status = await source.getStatus();
      expect(status?.usesNativeSessionIdentity, isTrue);
      expect(status?.profileId, isNull);
      expect(status?.sessionId, isNull);
      expect(calls.every((call) => call.method == 'getStatus'), isTrue);
    },
  );

  test(
    'first, measured zero and unavailable samples remain distinguishable',
    () async {
      source.reattach();
      events.add(
        _event(
          'stats',
          values: {
            'trafficAvailable': true,
            'uplinkTotal': 0,
            'downlinkTotal': 0,
          },
        ),
      );
      expect(statuses.last.trafficAvailable, isTrue);
      expect(statuses.last.ratesAvailable, isFalse);
      events.add(
        _event(
          'stats',
          values: {
            'trafficAvailable': true,
            'ratesAvailable': true,
            'uplinkTotal': 0,
            'downlinkTotal': 0,
            'uplink': 0,
            'downlink': 0,
          },
        ),
      );
      expect(statuses.last.ratesAvailable, isTrue);
      expect(statuses.last.uploadSpeed, 0);
      events.add(_event('stats'));
      expect(statuses.last.trafficAvailable, isFalse);
      expect(statuses.last.ratesAvailable, isFalse);
    },
  );

  test(
    'late stats and stopped packets from another session cannot replace this one',
    () async {
      await source.start(_proxy, profileId: 1);
      events.add(_event('connecting'));
      events.add(_event('started'));
      statuses.clear();
      events.add(_event('stats', values: {'sessionId': _sessionB}));
      events.add(_event('started', values: {'profileId': 2}));
      events.add(
        _event('stopped', values: {'profileId': 1, 'sessionId': _sessionB}),
      );
      expect(statuses, isEmpty);
      events.add(
        _event(
          'stats',
          values: {
            'trafficAvailable': true,
            'ratesAvailable': true,
            'uplinkTotal': 9000000000,
            'downlinkTotal': 12000000000,
            'uplink': 125,
            'downlink': 250,
          },
        ),
      );
      expect(statuses.single.upload, 9000000000);
      expect(statuses.single.download, 12000000000);
      expect(statuses.single.profileId, 1);
      expect(statuses.single.sessionId, _sessionA);
    },
  );

  test(
    'each native start carries a fresh UUID before events are attached',
    () async {
      source.dispose();
      source = AppleVpnDatasource(
        onStatusChanged: statuses.add,
        statusEvents: events.stream,
        prepareGeo: () async => {},
      );
      await source.start(_proxy, profileId: 1);
      await source.stop();
      await source.start(_proxy, profileId: 1);
      final ids = calls
          .where((call) => call.method == 'start')
          .map((call) => (call.arguments as Map)['sessionId'])
          .toList();
      final uuidV4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(ids, hasLength(2));
      expect(ids.every((id) => id is String && uuidV4.hasMatch(id)), isTrue);
      expect(ids[0], isNot(ids[1]));
      expect(statuses, isEmpty);
    },
  );

  test(
    'caller session identity rejects same-profile old events before the first new status',
    () async {
      await source.start(_proxy, profileId: 1);
      final request = calls.singleWhere((call) => call.method == 'start');
      expect((request.arguments as Map)['sessionId'], _sessionA);
      for (final event in ['connecting', 'started', 'stats', 'stopped']) {
        events.add(
          _event(event, values: {'profileId': 1, 'sessionId': _sessionB}),
        );
      }
      expect(statuses, isEmpty);
      expect(errors, isEmpty);
      snapshot = _event('started', values: {'sessionId': _sessionB});
      expect(await source.getStatus(), isNull);
      events.add(_event('connecting'));
      events.add(_event('started'));
      expect(statuses.map((status) => status.state), [
        'CONNECTING',
        'CONNECTED',
      ]);
      expect(statuses.last.sessionId, _sessionA);
    },
  );

  test(
    'native UUID canonical casing preserves caller identity and restoration',
    () async {
      const uuid = 'abcdef12-abcd-4abc-8abc-abcdef123456';
      source.dispose();
      source = AppleVpnDatasource(
        onStatusChanged: statuses.add,
        statusEvents: events.stream,
        prepareGeo: () async => {},
        createSessionId: () => uuid,
      );
      await source.start(_proxy, profileId: 1);
      events.add(
        _event('connecting', values: {'sessionId': uuid.toUpperCase()}),
      );
      events.add(_event('started', values: {'sessionId': uuid.toUpperCase()}));
      expect(statuses.map((status) => status.state), [
        'CONNECTING',
        'CONNECTED',
      ]);
      expect(statuses.last.sessionId, uuid);
      snapshot = _event('started', values: {'sessionId': uuid.toUpperCase()});
      expect((await source.getStatus())?.sessionId, uuid);
    },
  );

  test(
    'start rejected after stopped discovery cannot stop an unowned OS session',
    () async {
      expect((await source.getStatus())?.state, 'DISCONNECTED');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if (call.method == 'initialize') return true;
            if (call.method == 'start') {
              events.add(_event('started', values: {'sessionId': _sessionB}));
              throw PlatformException(
                code: 'APPLE_VPN_ERROR',
                message:
                    'Disconnect the current VPN before starting another session',
              );
            }
            return null;
          });
      await expectLater(
        source.start(_proxy, profileId: 1),
        throwsA(isA<PlatformException>()),
      );
      await source.stop();
      expect(calls.map((call) => call.method), [
        'getStatus',
        'initialize',
        'start',
      ]);
      expect(statuses, isEmpty);
    },
  );

  test(
    'accepted start can be stopped before the first started event',
    () async {
      await source.start(_proxy, profileId: 1);
      expect(statuses, isEmpty);
      await source.stop();
      expect(calls.map((call) => call.method), ['initialize', 'start', 'stop']);
    },
  );

  test('cancelling an unsubmitted request never invokes native stop', () async {
    await source.initialize();
    expect(await source.requestPermission(), isTrue);
    await source.stop();
    expect(calls.map((call) => call.method), [
      'initialize',
      'requestPermission',
    ]);
  });

  test(
    'snapshot timeout is bounded and a disposed late result is ignored',
    () async {
      final reply = Completer<dynamic>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return reply.future;
          });
      source.dispose();
      source = AppleVpnDatasource(
        onStatusChanged: statuses.add,
        statusEvents: events.stream,
        prepareGeo: () async => {},
        statusTimeout: const Duration(milliseconds: 10),
      );
      expect(await source.getStatus(), isNull);
      source.dispose();
      reply.complete(_event('started'));
      await Future<void>.delayed(Duration.zero);
      expect(source.lastStatus, isNull);
      expect(calls.map((call) => call.method), ['getStatus']);
      expect(statuses, isEmpty);
    },
  );

  testWidgets(
    'native deadline fallback survives the outer RPC and preference-loading budget',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return Future<Map<String, dynamic>>.delayed(
              const Duration(milliseconds: 2050),
              () => {
                'version': 1,
                'event': 'started',
                'running': true,
                'coreReady': false,
                'trafficAvailable': false,
                'ratesAvailable': false,
              },
            );
          });
      final reply = source.getStatus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2050));
      final status = await reply;
      expect(status?.state, 'CONNECTED');
      expect(status?.usesNativeSessionIdentity, isTrue);
      expect(status?.profileId, isNull);
      expect(status?.ratesAvailable, isFalse);
      expect(calls.map((call) => call.method), ['getStatus']);
    },
  );

  test(
    'legacy bool fallback is bounded when the old bridge never replies',
    () async {
      final reply = Completer<dynamic>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return reply.future;
          });
      source.dispose();
      source = AppleVpnDatasource(
        onStatusChanged: statuses.add,
        statusEvents: events.stream,
        prepareGeo: () async => {},
        statusTimeout: const Duration(milliseconds: 10),
      );
      expect(await source.checkRunning(), isFalse);
      expect(calls.map((call) => call.method), ['getStatus', 'checkStatus']);
      expect(statuses, isEmpty);
      reply.complete(null);
    },
  );

  test(
    'reattached connecting session can stop without a new-start failure',
    () async {
      snapshot = _event('connecting');
      expect((await source.getStatus())?.state, 'CONNECTING');
      source.reattach();
      events.add(_event('stopped'));
      expect(errors, isEmpty);
      expect(statuses.single.state, 'DISCONNECTED');
    },
  );

  test(
    'nonrunning stats and future event versions cannot claim connected',
    () async {
      source.reattach();
      events.add(_event('stats', values: {'running': false}));
      events.add(_event('started', values: {'version': 2}));
      expect(statuses, isEmpty);
      events.add({'event': 'started'});
      expect(statuses.single.state, 'CONNECTED');
      expect(statuses.single.profileId, isNull);
      expect(statuses.single.ratesAvailable, isFalse);
    },
  );

  test(
    'OS disconnecting preserves identity until the stopped transition',
    () async {
      source.reattach();
      events.add(_event('started'));
      events.add(_event('disconnecting'));
      expect(statuses.last.state, 'DISCONNECTING');
      expect(statuses.last.profileId, 1);
      expect(statuses.last.sessionId, _sessionA);
      expect(statuses.last.ratesAvailable, isFalse);
      events.add(_event('stopped'));
      expect(statuses.last.state, 'DISCONNECTED');
      expect(statuses.last.profileId, isNull);
      expect(source.lastStatus?.sessionId, isNull);
    },
  );
}
