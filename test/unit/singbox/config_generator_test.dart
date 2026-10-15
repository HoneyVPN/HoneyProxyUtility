import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/singbox_config_generator.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

const _proxy = ShadowsocksConfig(
  name: 'Test',
  host: 'example.com',
  port: 8388,
  method: 'chacha20-ietf-poly1305',
  password: 'test-password',
  plugin: '',
  pluginOpts: '',
);

void main() {
  const generator = SingboxConfigGenerator();

  Map<String, dynamic> config([AppSettings settings = const AppSettings()]) =>
      jsonDecode(generator.generateForAndroid(_proxy, settings))
          as Map<String, dynamic>;

  test(
    'Android exports the configured SOCKS port consumed by the native bridge',
    () {
      final result = config(
        const AppSettings(socksPort: 10808, httpPort: 10809),
      );
      final inbounds = (result['inbounds'] as List)
          .cast<Map<String, dynamic>>();
      expect(
        inbounds.singleWhere((i) => i['tag'] == 'socks-in')['listen_port'],
        10808,
      );
      expect(
        inbounds.singleWhere((i) => i['tag'] == 'http-in')['listen_port'],
        10809,
      );
      expect(inbounds.every((i) => i['listen'] == '127.0.0.1'), isTrue);
    },
  );

  test('global routing does not bypass Russian destinations', () {
    final route =
        config(const AppSettings(routingMode: RoutingMode.global))['route']
            as Map;
    expect(route.containsKey('rule_set'), isFalse);
    expect(
      (route['rules'] as List).any((r) => (r as Map).containsKey('rule_set')),
      isFalse,
    );
    expect(route['final'], 'proxy');
  });

  test(
    'bypass RU keeps blocked destinations on proxy before the direct rule',
    () {
      final route = config()['route'] as Map;
      final rules = (route['rules'] as List).cast<Map>();
      final blocked = rules.indexWhere((r) => r['rule_set'] == 'ru-blocked');
      final direct = rules.indexWhere(
        (r) => r['rule_set'] == 'ru' && r['outbound'] == 'direct',
      );
      expect(blocked, greaterThanOrEqualTo(0));
      expect(blocked, lessThan(direct));
      expect(rules[blocked]['outbound'], 'proxy');
    },
  );

  test('selected DoH provider is used through proxy', () {
    final dns =
        config(const AppSettings(dnsPreset: DnsPreset.adguard))['dns'] as Map;
    final remote = (dns['servers'] as List).cast<Map>().singleWhere(
      (s) => s['tag'] == 'remote-dns',
    );
    expect(remote['type'], 'https');
    expect(remote['server'], '94.140.14.14');
    expect(remote['detour'], 'proxy');
  });

  test('Russia routing cannot send client DNS to the bootstrap resolver', () {
    for (final mode in [RoutingMode.bypassRU, RoutingMode.rules]) {
      final result = config(AppSettings(routingMode: mode));
      final dns = result['dns'] as Map;
      expect(dns['final'], 'remote-dns');
      expect(dns['rules'], isEmpty);
      expect(result['route']['default_domain_resolver']['server'], 'local-dns');
      expect(
        (result['route']['rules'] as List).any(
          (r) => r['rule_set'] == 'ru' && r['outbound'] == 'direct',
        ),
        isTrue,
      );
    }
  });

  test('fragmentation emits a supported route-options action', () {
    final rules =
        (config(const AppSettings(fragmentationEnabled: true))['route']['rules']
                as List)
            .cast<Map>();
    final fragment = rules.singleWhere((r) => r['tls_fragment'] == true);
    expect(fragment['action'], 'route-options');
    expect(fragment['network'], 'tcp');
    expect(fragment['protocol'], 'tls');
  });

  test(
    'unsupported saved custom DNS cannot silently select a different server',
    () {
      for (final address in [
        '',
        'udp://dns.example',
        'https://dns.example:0/query',
        'tls://dns.example:65536',
        'https://private@dns.example/query',
        'https://dns.example/query?token=private',
        'tls://dns.example/custom-path',
        'https://dns.example:invalid/query',
      ]) {
        expect(
          () => config(
            AppSettings(dnsPreset: DnsPreset.custom, customDnsUrl: address),
          ),
          throwsA(
            isA<SettingsValidationException>().having(
              (e) => e.toString(),
              'safe error',
              isNot(contains(address.isEmpty ? 'dns.example' : address)),
            ),
          ),
        );
      }
    },
  );

  test('custom DNS preserves explicit HTTPS and TLS ports', () {
    for (final entry in {
      'https://dns.example:8443/custom-query': 8443,
      'tls://dns.example:8853': 8853,
    }.entries) {
      final result = config(
        AppSettings(dnsPreset: DnsPreset.custom, customDnsUrl: entry.key),
      );
      final remote = (result['dns']['servers'] as List).cast<Map>().singleWhere(
        (server) => server['tag'] == 'remote-dns',
      );
      expect(remote['server'], 'dns.example');
      expect(remote['server_port'], entry.value);
      expect(remote['detour'], 'proxy');
      if (remote['type'] == 'https') expect(remote['path'], '/custom-query');
    }
  });

  test('listener ports cannot collide with the Android core status API', () {
    expect(
      () => config(const AppSettings(socksPort: 9090, httpPort: 8080)),
      throwsArgumentError,
    );
    expect(
      () => config(const AppSettings(socksPort: 8080, httpPort: 9090)),
      throwsArgumentError,
    );
  });

  test('VLESS without transport security does not enable TLS', () {
    const proxy = VlessConfig(
      name: 'Plain VLESS',
      host: 'example.com',
      port: 80,
      uuid: 'a3482e88-686a-4a58-8126-99c9df64b7bf',
      flow: '',
      encryption: 'none',
      security: 'none',
      sni: '',
      fingerprint: '',
      publicKey: '',
      shortId: '',
      spiderX: '',
      transport: 'tcp',
      path: '',
      transportHost: '',
      grpcServiceName: '',
    );
    final result =
        jsonDecode(generator.generateForAndroid(proxy, const AppSettings()))
            as Map;
    expect((result['outbounds'] as List).first.containsKey('tls'), isFalse);
  });

  test(
    'Hysteria2 rejects unsupported certificate pins and excludes TCP multiplexing',
    () {
      Hysteria2Config profile(String pin) => Hysteria2Config(
        name: 'HY2',
        host: 'example.com',
        port: 443,
        auth: 'auth',
        sni: 'example.com',
        insecure: false,
        obfs: '',
        obfsPassword: '',
        pinSha256: pin,
      );
      const fingerprint =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect(
        () => generator.generateForAndroid(
          profile(fingerprint),
          const AppSettings(),
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'safe reason',
            allOf(contains('pinSHA256'), isNot(contains(fingerprint))),
          ),
        ),
      );
      final result =
          jsonDecode(
                generator.generateForAndroid(
                  profile(''),
                  const AppSettings(multiplexerEnabled: true),
                ),
              )
              as Map;
      final out = (result['outbounds'] as List).first as Map;
      expect(out.containsKey('multiplex'), isFalse);
      expect(out['tls']['enabled'], isTrue);
      expect(out['tls']['insecure'], isFalse);
      expect(
        out['tls'].containsKey('pinned_peer_certificate_chain_sha256'),
        isFalse,
      );
    },
  );
}
