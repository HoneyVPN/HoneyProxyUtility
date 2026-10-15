import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/vpn_datasource_windows.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/vless_parser.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

const _ss = ShadowsocksConfig(
  name: 'SS',
  host: 'example.com',
  port: 8388,
  method: 'chacha20-ietf-poly1305',
  password: 'test-password',
  plugin: '',
  pluginOpts: '',
);

void main() {
  final datasource = WindowsVpnDatasource(onStatusChanged: (_) {});

  for (final mode in ConnectionMode.values) {
    group(mode.name, () {
      test('plain VLESS stays plain after link import', () {
        final proxy = const VlessParser().parse(
          'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@example.com:80?security=none&type=tcp#Plain',
        );
        final config = datasource.buildConfiguration(
          proxy,
          const AppSettings(),
          mode: mode,
        );
        expect((config['outbounds'] as List).first.containsKey('tls'), isFalse);
      });

      test('Reality link retains TLS, public key and fingerprint', () {
        final proxy = const VlessParser().parse(
          'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@example.com:443?security=reality&sni=cdn.example.com&fp=chrome&pbk=test-key&sid=abcd&type=tcp#Reality',
        );
        final config = datasource.buildConfiguration(
          proxy,
          const AppSettings(),
          mode: mode,
        );
        final tls = (config['outbounds'] as List).first['tls'] as Map;
        expect(tls['enabled'], isTrue);
        expect(tls['server_name'], 'cdn.example.com');
        expect(tls['reality']['public_key'], 'test-key');
        expect(tls['utls']['fingerprint'], 'chrome');
      });

      test('global routing never installs RU bypass rules', () {
        final config = datasource.buildConfiguration(
          _ss,
          const AppSettings(routingMode: RoutingMode.global),
          mode: mode,
        );
        final route = config['route'] as Map;
        expect(route.containsKey('rule_set'), isFalse);
        expect(
          (route['rules'] as List).any(
            (r) => (r as Map).containsKey('rule_set'),
          ),
          isFalse,
        );
      });

      test('RU bypass prioritizes blocked destinations through proxy', () {
        final config = datasource.buildConfiguration(
          _ss,
          const AppSettings(routingMode: RoutingMode.bypassRU),
          mode: mode,
        );
        final route = config['route'] as Map;
        final rules = (route['rules'] as List).cast<Map>();
        final blocked = rules.indexWhere((r) => r['rule_set'] == 'ru-blocked');
        final direct = rules.indexWhere((r) => r['rule_set'] == 'ru');
        expect(blocked, greaterThanOrEqualTo(0));
        expect(blocked, lessThan(direct));
        expect(rules[blocked]['outbound'], 'proxy');
        expect(rules[direct]['outbound'], 'direct');
        expect((route['rule_set'] as List).length, 4);
      });

      test('RU direct policy excludes IPv6 even with IPv6 DNS preference', () {
        for (final preference in [IpType.both, IpType.ipv6]) {
          final config = datasource.buildConfiguration(
            _ss,
            AppSettings(
              routingMode: RoutingMode.bypassRU,
              preferredIpType: preference,
            ),
            mode: mode,
          );
          final route = config['route'] as Map;
          final rules = (route['rules'] as List).cast<Map>();
          final russian = rules.singleWhere((r) => r['rule_set'] == 'ru');
          expect(russian['ip_version'], 4);
          expect(russian['outbound'], 'direct');
          // Russia's IPv6 prefixes do not match this direct rule, so public
          // IPv6 retains the proxy fallback regardless of DNS preference.
          expect(route['final'], 'proxy');
          expect(
            rules.any((r) => r['rule_set'] == 'ru' && r['ip_version'] != 4),
            isFalse,
          );
        }
      });

      test(
        'RU IP routing does not first send client DNS to the local server',
        () {
          final config = datasource.buildConfiguration(
            _ss,
            const AppSettings(routingMode: RoutingMode.bypassRU),
            mode: mode,
          );
          final dns = config['dns'] as Map;
          expect(dns['final'], 'remote');
          // IP-only rule sets cannot choose a DNS server before an answer exists.
          expect(dns['rules'], isEmpty);
          expect(config['route']['default_domain_resolver'], {
            'server': 'local',
            'strategy': 'prefer_ipv4',
          });
          expect(
            (config['route']['rules'] as List).any(
              (rule) => rule['rule_set'] == 'ru',
            ),
            isTrue,
          );
        },
      );

      test('custom DNS, IP preference and log level reach the engine', () {
        const settings = AppSettings(
          dnsPreset: DnsPreset.custom,
          customDnsUrl: 'https://dns.example.com/dns-query',
          preferredIpType: IpType.ipv4,
          logLevel: LogLevel.error,
        );
        final config = datasource.buildConfiguration(_ss, settings, mode: mode);
        final dns = config['dns'] as Map;
        final remote = (dns['servers'] as List).cast<Map>().singleWhere(
          (s) => s['tag'] == 'remote',
        );
        expect(remote['type'], 'https');
        expect(remote['server'], 'dns.example.com');
        expect(remote['path'], '/dns-query');
        expect(remote['detour'], 'proxy');
        expect(remote['domain_resolver'], {
          'server': 'local',
          'strategy': 'ipv4_only',
        });
        expect(dns['strategy'], 'ipv4_only');
        expect(config['log']['level'], 'error');
      });

      test('built-in DNS uses HTTPS through the selected server', () {
        for (final preset in [
          DnsPreset.cloudflare,
          DnsPreset.google,
          DnsPreset.adguard,
        ]) {
          final config = datasource.buildConfiguration(
            _ss,
            AppSettings(dnsPreset: preset),
            mode: mode,
          );
          final remote = (config['dns']['servers'] as List).cast<Map>().first;
          expect(remote['type'], 'https');
          expect(remote['path'], '/dns-query');
          expect(remote.containsKey('address'), isFalse);
          expect(remote.containsKey('address_resolver'), isFalse);
          expect(remote['detour'], 'proxy');
        }
      });

      test(
        'unsupported saved DNS is rejected instead of changing its meaning',
        () {
          for (final address in [
            '',
            'https://dns.example.com:0/dns-query',
            'https://dns.example.com:65536/dns-query',
            'https://dns.example.com/dns-query?token=example',
            'https://user:example@dns.example.com/dns-query',
            'tls://dns.example.com/path',
          ]) {
            expect(
              () => datasource.buildConfiguration(
                _ss,
                AppSettings(dnsPreset: DnsPreset.custom, customDnsUrl: address),
                mode: mode,
              ),
              throwsA(isA<SettingsValidationException>()),
              reason: address,
            );
          }
        },
      );

      test('packaged RU routing starts without any remote rule-set', () {
        final geo = {
          for (final name in [
            'ru-blocked.srs',
            'ru-blocked-community.srs',
            're-filter.srs',
            'ru.srs',
          ])
            name: 'C:\\Users\\Test User\\geo\\$name',
        };
        final config = datasource.buildConfiguration(
          _ss,
          const AppSettings(),
          mode: mode,
          geoPaths: geo,
        );
        final sets = (config['route']['rule_set'] as List).cast<Map>();
        expect(sets, hasLength(4));
        expect(sets.every((s) => s['type'] == 'local'), isTrue);
        expect(sets.map((s) => s['path']), unorderedEquals(geo.values));
        expect(sets.any((s) => s.containsKey('url')), isFalse);
        expect(
          () => datasource.buildConfiguration(
            _ss,
            const AppSettings(),
            mode: mode,
            geoPaths: {},
          ),
          throwsStateError,
        );
      });

      test('fragmentation uses route-options and multiplexing is applied', () {
        final config = datasource.buildConfiguration(
          _ss,
          const AppSettings(
            fragmentationEnabled: true,
            multiplexerEnabled: true,
          ),
          mode: mode,
        );
        final rules = (config['route']['rules'] as List).cast<Map>();
        expect(
          rules.singleWhere((r) => r['tls_fragment'] == true)['action'],
          'route-options',
        );
        expect(
          (config['outbounds'] as List).first['multiplex']['enabled'],
          isTrue,
        );
      });
    });
  }

  test('TUN stack and physical interface survive settings generation', () {
    final config = datasource.buildConfiguration(
      _ss,
      const AppSettings(tunStack: TunStack.gvisor),
      bindInterface: 'Ethernet',
      excludeAddresses: ['192.0.2.1/32'],
    );
    final tun = (config['inbounds'] as List).first as Map;
    expect(tun['stack'], 'gvisor');
    expect(tun['route_exclude_address'], ['192.0.2.1/32']);
    expect((config['outbounds'] as List).first['bind_interface'], 'Ethernet');
  });

  for (final preference in IpType.values) {
    test('TUN routes both packet families with ${preference.name} DNS', () {
      final config = datasource.buildConfiguration(
        _ss,
        AppSettings(preferredIpType: preference),
      );
      final tun = (config['inbounds'] as List).single as Map;
      expect(tun['address'], ['198.18.0.1/16', 'fdfe:dcba:9876::1/126']);
      expect(tun['auto_route'], isTrue);
      expect(config['dns']['strategy'], switch (preference) {
        IpType.ipv4 => 'ipv4_only',
        IpType.ipv6 => 'ipv6_only',
        IpType.both => 'prefer_ipv4',
      });
    });
  }

  test('proxy mode honors custom listening ports and LAN permission', () {
    final config = datasource.buildConfiguration(
      _ss,
      const AppSettings(
        socksPort: 10808,
        httpPort: 10809,
        allowLanConnections: true,
      ),
      mode: ConnectionMode.proxy,
    );
    final inbounds = (config['inbounds'] as List).cast<Map>();
    expect(
      inbounds.singleWhere((s) => s['type'] == 'socks')['listen_port'],
      10808,
    );
    expect(
      inbounds.singleWhere((s) => s['type'] == 'http')['listen_port'],
      10809,
    );
    expect(inbounds.every((s) => s['listen'] == '0.0.0.0'), isTrue);
  });

  for (final mode in ConnectionMode.values) {
    for (final awg in [false, true]) {
      ParsedProxy node(List<int>? reserved) => awg
          ? AmneziaWGConfig(
              name: 'Synthetic AWG',
              host: 'peer.example.test',
              port: 51820,
              privateKey: 'synthetic-private-key',
              publicKey: 'synthetic-public-key',
              presharedKey: '',
              addresses: ['10.20.0.2/32'],
              dns: [],
              mtu: 1420,
              reserved: reserved,
            )
          : WireGuardConfig(
              name: 'Synthetic WG',
              host: 'peer.example.test',
              port: 51820,
              privateKey: 'synthetic-private-key',
              publicKey: 'synthetic-public-key',
              presharedKey: '',
              addresses: ['10.20.0.2/32'],
              dns: [],
              mtu: 1420,
              reserved: reserved,
            );

      test(
        '${mode.name} ${awg ? 'AWG' : 'WG'} absent or zero reserved preserves the stored profile',
        () {
          for (final reserved in [
            null,
            <int>[],
            <int>[0, 0, 0],
          ]) {
            final profile = node(reserved);
            final config = datasource.buildConfiguration(
              profile,
              const AppSettings(),
              mode: mode,
            );
            final peer = config['endpoints'][0]['peers'][0] as Map;
            expect(peer.containsKey('reserved'), isFalse);
            expect(
              awg
                  ? (profile as AmneziaWGConfig).reserved
                  : (profile as WireGuardConfig).reserved,
              reserved,
            );
          }
        },
      );
      test(
        '${mode.name} ${awg ? 'AWG' : 'WG'} rejects unsupported and malformed cached reserved',
        () async {
          for (final reserved in <List<int>>[
            [1, 0, 0],
            [0, 7, 0],
            [0, 0, 9],
            [0, 0],
            [0, 0, 0, 0],
            [-1, 0, 0],
            [256, 0, 0],
          ]) {
            final profile = node(reserved);
            expect(
              () => datasource.buildConfiguration(
                profile,
                const AppSettings(),
                mode: mode,
              ),
              throwsUnsupportedError,
            );
            // The startup guard must run before stop/interface/path/process work.
            await expectLater(
              datasource.start(profile, mode: mode),
              throwsUnsupportedError,
            );
            expect(
              awg
                  ? (profile as AmneziaWGConfig).reserved
                  : (profile as WireGuardConfig).reserved,
              reserved,
            );
          }
        },
      );
      for (final preference in IpType.values) {
        test(
          '${mode.name} ${awg ? 'AWG' : 'WG'} resolves bootstrap with ${preference.name}',
          () {
            final settings = AppSettings(preferredIpType: preference);
            final config = datasource.buildConfiguration(
              node(null),
              settings,
              mode: mode,
            );
            final expected = {
              'server': 'local',
              'strategy': switch (preference) {
                IpType.ipv4 => 'ipv4_only',
                IpType.ipv6 => 'ipv6_only',
                IpType.both => 'prefer_ipv4',
              },
            };
            expect(config['route']['default_domain_resolver'], expected);
            expect(config['endpoints'][0]['domain_resolver'], expected);
            expect(config['dns']['servers'][0]['domain_resolver'], expected);
            expect(config['dns']['strategy'], expected['strategy']);
          },
        );
      }
    }
    test(
      '${mode.name} typed custom DNS keeps port, path and IPv6 identity',
      () {
        for (final address in [
          'https://dns.example.test:443/custom-dns',
          'https://dns.example.test:8443/custom-dns',
          'tls://dns.example.test:853',
          'tls://dns.example.test:8853/',
          'https://[2001:db8::53]:8443/custom-dns',
          'tls://[2001:db8::53]:8853',
        ]) {
          final uri = Uri.parse(address);
          final config = datasource.buildConfiguration(
            _ss,
            AppSettings(dnsPreset: DnsPreset.custom, customDnsUrl: address),
            mode: mode,
          );
          final remote = config['dns']['servers'][0] as Map;
          expect(remote['type'], uri.scheme);
          expect(remote['server'], uri.host);
          expect(remote['server_port'], uri.hasPort ? uri.port : null);
          if (uri.scheme == 'https') {
            expect(remote['path'], '/custom-dns');
          } else {
            expect(remote.containsKey('path'), isFalse);
          }
          expect(config['dns']['servers'][1], {
            'tag': 'local',
            'type': 'local',
            'detour': 'direct',
          });
        }
      },
    );
  }
}
