import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/vpn_datasource_windows.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/vless_parser.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

// These combinations cover every visible DNS, address preference, stack and
// log level. The same TUN files cross the SYSTEM validator in Windows CI.
const _settingsCases = {
  'ipv4-system-cloudflare': (
    settings: AppSettings(
      routingMode: RoutingMode.global,
      preferredIpType: IpType.ipv4,
      tunStack: TunStack.system,
      logLevel: LogLevel.trace,
      fragmentationEnabled: true,
      multiplexerEnabled: true,
      socksPort: 12080,
      httpPort: 12081,
      allowLanConnections: true,
    ),
    dns: 'https://1.1.1.1/dns-query',
    strategy: 'ipv4_only',
  ),
  'ipv6-gvisor-google': (
    settings: AppSettings(
      dnsPreset: DnsPreset.google,
      preferredIpType: IpType.ipv6,
      tunStack: TunStack.gvisor,
      logLevel: LogLevel.debug,
    ),
    dns: 'https://8.8.8.8/dns-query',
    strategy: 'ipv6_only',
  ),
  'both-mixed-adguard': (
    settings: AppSettings(
      dnsPreset: DnsPreset.adguard,
      routingMode: RoutingMode.rules,
      logLevel: LogLevel.info,
      fragmentationEnabled: true,
    ),
    dns: 'https://94.140.14.14/dns-query',
    strategy: 'prefer_ipv4',
  ),
  'custom-https': (
    settings: AppSettings(
      dnsPreset: DnsPreset.custom,
      customDnsUrl: 'https://dns.example.test/dns-query',
      routingMode: RoutingMode.global,
      logLevel: LogLevel.error,
      multiplexerEnabled: true,
    ),
    dns: 'https://dns.example.test/dns-query',
    strategy: 'prefer_ipv4',
  ),
  'custom-tls': (
    settings: AppSettings(
      dnsPreset: DnsPreset.custom,
      customDnsUrl: 'tls://dns.example.test',
      routingMode: RoutingMode.global,
      preferredIpType: IpType.ipv4,
    ),
    dns: 'tls://dns.example.test',
    strategy: 'ipv4_only',
  ),
  'custom-https-port': (
    settings: AppSettings(
      dnsPreset: DnsPreset.custom,
      customDnsUrl: 'https://dns.example.test:8443/custom-dns',
      preferredIpType: IpType.ipv6,
    ),
    dns: 'https://dns.example.test:8443/custom-dns',
    strategy: 'ipv6_only',
  ),
  'custom-tls-port': (
    settings: AppSettings(
      dnsPreset: DnsPreset.custom,
      customDnsUrl: 'tls://dns.example.test:8853',
    ),
    dns: 'tls://dns.example.test:8853',
    strategy: 'prefer_ipv4',
  ),
  'custom-ipv6-port': (
    settings: AppSettings(
      dnsPreset: DnsPreset.custom,
      customDnsUrl: 'https://[2001:db8::53]:8443/custom-dns',
    ),
    dns: 'https://[2001:db8::53]:8443/custom-dns',
    strategy: 'prefer_ipv4',
  ),
};
Map<String, String> get _environment => Map.fromEntries(
  Platform.environment.entries.where(
    (entry) => !entry.key.startsWith('ENABLE_DEPRECATED_'),
  ),
);

void main() {
  final datasource = WindowsVpnDatasource(onStatusChanged: (_) {});
  final proxy = const VlessParser().parse(
    'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@192.0.2.10:443?security=none&type=tcp',
  );
  final geoPaths = {
    for (final name in [
      'ru-blocked.srs',
      'ru-blocked-community.srs',
      're-filter.srs',
      'ru.srs',
    ])
      name: File('assets/geo/$name').absolute.path,
  };
  Map<String, dynamic> configuration(
    AppSettings settings,
    ConnectionMode mode,
  ) => datasource.buildConfiguration(
    proxy,
    settings,
    mode: mode,
    geoPaths: geoPaths,
  );

  final binary =
      Platform.environment['SINGBOX_CHECK_TARGET']?.trim() == 'android'
      ? ''
      : (Platform.environment['SINGBOX_WINDOWS_CHECK_BINARY'] ??
                    Platform.environment['SINGBOX_CHECK_BINARY'])
                ?.trim() ??
            '';
  final exportDirectory =
      Platform.environment['CORE_CONFIG_OUTPUT_DIR']?.trim() ?? '';
  for (final entry in _settingsCases.entries) {
    final settings = entry.value.settings;
    for (final mode in ConnectionMode.values) {
      test('${mode.name} retains ${entry.key} settings', () {
        final config = configuration(settings, mode);
        final dns = config['dns'] as Map;
        final servers = (dns['servers'] as List).cast<Map>();
        expect(dns['strategy'], entry.value.strategy);
        final remote = servers.singleWhere(
          (server) => server['tag'] == 'remote',
        );
        final address = Uri.parse(entry.value.dns);
        expect(remote['type'], address.scheme);
        expect(remote['server'], address.host);
        expect(remote['server_port'], address.hasPort ? address.port : null);
        expect(remote['path'], address.scheme == 'https' ? address.path : null);
        expect(remote['domain_resolver'], {
          'server': 'local',
          'strategy': entry.value.strategy,
        });
        expect(remote['detour'], 'proxy');
        expect(dns['rules'], isEmpty);
        expect(config['log']['level'], settings.logLevel.name);

        final route = config['route'] as Map;
        expect(route['default_domain_resolver'], {
          'server': 'local',
          'strategy': entry.value.strategy,
        });
        final rules = (route['rules'] as List).cast<Map>();
        expect(
          rules.any((rule) => rule['tls_fragment'] == true),
          settings.fragmentationEnabled,
        );
        if (settings.fragmentationEnabled) {
          expect(rules.singleWhere((rule) => rule['tls_fragment'] == true), {
            'action': 'route-options',
            'tls_fragment': true,
            'tls_fragment_fallback_delay': '500ms',
          });
        }
        expect(
          route.containsKey('rule_set'),
          settings.routingMode != RoutingMode.global,
        );
        final out = (config['outbounds'] as List).cast<Map>().first;
        expect(out.containsKey('multiplex'), settings.multiplexerEnabled);
        if (settings.multiplexerEnabled) {
          expect(out['multiplex']['enabled'], isTrue);
          expect(out['multiplex']['protocol'], 'smux');
        }
        final inbounds = (config['inbounds'] as List).cast<Map>();
        if (mode == ConnectionMode.tunnel) {
          expect(inbounds, hasLength(1));
          final tun = inbounds.single;
          expect(tun['type'], 'tun');
          expect(tun['stack'], settings.tunStack.name);
          expect(tun['address'], ['198.18.0.1/16', 'fdfe:dcba:9876::1/126']);
          expect(tun.containsKey('listen_port'), isFalse);
        } else {
          expect(inbounds, hasLength(2));
          expect(
            inbounds.singleWhere(
              (inbound) => inbound['type'] == 'socks',
            )['listen_port'],
            settings.socksPort,
          );
          expect(
            inbounds.singleWhere(
              (inbound) => inbound['type'] == 'http',
            )['listen_port'],
            settings.httpPort,
          );
          expect(inbounds.map((inbound) => inbound['listen']).toSet(), {
            settings.allowLanConnections ? '0.0.0.0' : '127.0.0.1',
          });
        }
      });

      test(
        'packaged core accepts ${mode.name} ${entry.key}',
        () async {
          final scratch = await Directory.systemTemp.createTemp(
            'honey-settings-',
          );
          try {
            final file = File('${scratch.path}/config.json');
            await file.writeAsString(jsonEncode(configuration(settings, mode)));
            final result = await Process.run(
              binary,
              ['check', '--disable-color', '-c', file.path],
              environment: _environment,
              includeParentEnvironment: false,
            ).timeout(const Duration(seconds: 20));
            // Synthetic configuration only: no VPN or node traffic is started.
            expect(result.exitCode, 0, reason: result.stderr.toString());
          } finally {
            await scratch.delete(recursive: true);
          }
        },
        skip: binary.isEmpty ? 'SINGBOX_CHECK_BINARY is not configured' : false,
      );
    }
  }
  test(
    'export settings combinations for the privileged validator',
    () async {
      final output = await Directory(exportDirectory).create(recursive: true);
      for (final entry in _settingsCases.entries) {
        await File(
          '${output.path}/windowsTunnel-settings-${entry.key}.json',
        ).writeAsString(
          jsonEncode(
            configuration(entry.value.settings, ConnectionMode.tunnel),
          ),
        );
      }
    },
    skip: exportDirectory.isEmpty
        ? 'CORE_CONFIG_OUTPUT_DIR is not configured'
        : false,
  );
}
