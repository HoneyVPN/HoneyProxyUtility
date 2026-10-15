import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/vpn_datasource_windows.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/singbox_config_generator.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/base_parser.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/vless_parser.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/servers/data/services/profile_latency_service.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

const _realityKey = 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0';
const _settings = AppSettings(routingMode: RoutingMode.global);

VlessConfig _profile(
  String security,
  String fingerprint, {
  String transport = 'tcp',
  List<String> alpn = const [],
}) => VlessConfig(
  name: 'Synthetic VLESS',
  host: '192.0.2.10',
  port: 443,
  uuid: 'a3482e88-686a-4a58-8126-99c9df64b7bf',
  flow: transport == 'tcp' ? 'xtls-rprx-vision' : '',
  encryption: 'none',
  security: security,
  sni: 'cover.example.test',
  fingerprint: fingerprint,
  publicKey: security == 'reality' ? _realityKey : '',
  shortId: security == 'reality' ? 'abcd' : '',
  spiderX: '',
  transport: transport,
  path: '/',
  transportHost: '',
  grpcServiceName: '',
  alpn: alpn,
);

Map<String, dynamic> _tls(Map<String, dynamic> config) =>
    (config['outbounds'] as List).first['tls'] as Map<String, dynamic>;

void main() {
  final windows = WindowsVpnDatasource(onStatusChanged: (_) {});
  const generator = SingboxConfigGenerator();

  Map<String, Map<String, dynamic>> configurations(VlessConfig proxy) => {
    for (final mode in ConnectionMode.values)
      'Windows ${mode.name}': windows.buildConfiguration(
        proxy,
        _settings,
        mode: mode,
      ),
    'Android': jsonDecode(generator.generateForAndroid(proxy, _settings)),
    'latency': jsonDecode(
      IsolatedCoreLatencyService.configuration(
        proxy,
        12345,
        'synthetic-test-secret',
        windowsRouting: true,
      ),
    ),
  };

  for (final (label, security, fingerprint, expectedFingerprint) in [
    ('Reality without fingerprint', 'reality', '', 'chrome'),
    ('Reality with explicit Firefox', 'reality', 'firefox', 'firefox'),
    ('ordinary TLS without fingerprint', 'tls', '', null),
    ('ordinary TLS with explicit Firefox', 'tls', 'firefox', 'firefox'),
  ]) {
    test(
      '$label retains compatible TLS across connection and latency paths',
      () {
        // Direct models also represent saved profiles; correctness must not rely
        // on the URI parser filling a default during a new import.
        final proxy = _profile(security, fingerprint);
        for (final entry in configurations(proxy).entries) {
          final tls = _tls(entry.value);
          expect(tls['enabled'], isTrue, reason: entry.key);
          expect(tls['server_name'], 'cover.example.test', reason: entry.key);
          if (expectedFingerprint == null) {
            expect(tls.containsKey('utls'), isFalse, reason: entry.key);
          } else {
            expect(tls['utls'], {
              'enabled': true,
              'fingerprint': expectedFingerprint,
            }, reason: entry.key);
          }
          if (security == 'reality') {
            expect(tls['reality'], {
              'enabled': true,
              'public_key': _realityKey,
              'short_id': 'abcd',
            }, reason: entry.key);
          } else {
            expect(tls.containsKey('reality'), isFalse, reason: entry.key);
          }
        }
        expect(proxy.fingerprint, fingerprint);
      },
    );
  }

  for (final (security, transport, configuredAlpn, expectedAlpn) in [
    ('reality', 'xhttp', <String>[], ['h2']),
    ('tls', 'xhttp', <String>[], ['h2']),
    ('none', 'xhttp', <String>[], <String>[]),
    ('reality', 'xhttp', ['h2', 'http/1.1'], ['h2', 'http/1.1']),
    ('tls', 'xhttp', ['h3'], ['h3']),
    ('reality', 'tcp', <String>[], <String>[]),
    ('reality', 'grpc', <String>[], <String>[]),
    ('reality', 'tcp', ['http/1.1'], ['http/1.1']),
  ]) {
    test(
      '$security $transport preserves ALPN policy across saved-model paths',
      () {
        final proxy = _profile(
          security,
          'ios',
          transport: transport,
          alpn: configuredAlpn,
        );
        for (final entry in configurations(proxy).entries) {
          final outbound = (entry.value['outbounds'] as List).first as Map;
          if (security == 'none') {
            expect(outbound.containsKey('tls'), isFalse, reason: entry.key);
            continue;
          }
          final tls = _tls(entry.value);
          if (expectedAlpn.isEmpty) {
            expect(tls.containsKey('alpn'), isFalse, reason: entry.key);
          } else {
            expect(tls['alpn'], expectedAlpn, reason: entry.key);
          }
          expect(tls['utls']['fingerprint'], 'ios', reason: entry.key);
        }
        expect(proxy.alpn, configuredAlpn);
      },
    );
  }

  test(
    'Reality xHTTP rejects HTTP/3 before any native resources are started',
    () {
      final proxy = _profile(
        'reality',
        'ios',
        transport: 'xhttp',
        alpn: ['h3'],
      );
      for (final mode in ConnectionMode.values) {
        expect(
          () => windows.buildConfiguration(proxy, _settings, mode: mode),
          throwsUnsupportedError,
        );
      }
      expect(
        () => generator.generateForAndroid(proxy, _settings),
        throwsUnsupportedError,
      );
      expect(
        () => IsolatedCoreLatencyService.configuration(proxy, 12345, 'test'),
        throwsUnsupportedError,
      );
    },
  );

  for (final alpn in ['http/1.1', 'http/1.1,h2', 'h3']) {
    test('import rejects unsupported Reality xHTTP ALPN $alpn', () {
      expect(
        () => const VlessParser().parse(
          'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@192.0.2.10:443'
          '?security=reality&sni=cover.example.test&type=xhttp&mode=auto&fp=ios'
          '&pbk=$_realityKey&sid=0123456789abcdef&alpn=$alpn',
        ),
        throwsA(isA<UnsupportedConfigurationException>()),
      );
    });
  }

  for (final security in ['tls', 'reality']) {
    for (final alpn in [
      ['http/1.1'],
      ['http/1.1', 'h2'],
    ]) {
      test(
        '$security xHTTP rejects first HTTP/1.1 before generating traffic',
        () {
          final proxy = _profile(
            security,
            'ios',
            transport: 'xhttp',
            alpn: alpn,
          );
          for (final mode in ConnectionMode.values) {
            expect(
              () => windows.buildConfiguration(proxy, _settings, mode: mode),
              throwsUnsupportedError,
            );
          }
          expect(
            () => generator.generateForAndroid(proxy, _settings),
            throwsUnsupportedError,
          );
          expect(
            () =>
                IsolatedCoreLatencyService.configuration(proxy, 12345, 'test'),
            throwsUnsupportedError,
          );
        },
      );
    }
  }

  test(
    'an imported iOS Reality xHTTP link gets HTTP/2 on reconnect and ping',
    () {
      final proxy = const VlessParser().parse(
        'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@192.0.2.10:443'
        '?security=reality&sni=cover.example.test&type=xhttp&mode=auto&fp=ios'
        '&pbk=$_realityKey&sid=0123456789abcdef&path=%2Fsynthetic',
      );
      expect(proxy.alpn, isEmpty);
      for (final config in configurations(proxy).values) {
        expect(_tls(config)['alpn'], ['h2']);
        expect(_tls(config)['utls']['fingerprint'], 'ios');
      }
    },
  );

  test(
    'an imported Reality URI without fp remains usable on later reconnect',
    () {
      final proxy = const VlessParser().parse(
        'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@192.0.2.10:443'
        '?security=reality&sni=cover.example.test&type=tcp'
        '&pbk=$_realityKey&sid=abcd&flow=xtls-rprx-vision',
      );
      expect(proxy.fingerprint, isEmpty);
      expect(_tls(windows.buildConfiguration(proxy, _settings))['utls'], {
        'enabled': true,
        'fingerprint': 'chrome',
      });
    },
  );
}
