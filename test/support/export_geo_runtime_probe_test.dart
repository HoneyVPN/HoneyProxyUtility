import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/vpn_datasource_windows.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/provider_geo_bundle.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/vless_parser.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

// Run explicitly with HONEY_GEO_PROBE_OUTPUT_DIR. Exports artificial data only;
// the companion native probe replaces transport endpoints with loopback sinks.
void main() {
  final output = Platform.environment['HONEY_GEO_PROBE_OUTPUT_DIR'] ?? '';
  test(
    'export exact synthetic Windows routing and DoH policy',
    () async {
      final root = Directory(output);
      expect(await root.exists(), isFalse);
      await root.create(recursive: true);
      final geo = <String, String>{};
      final files = <Map<String, Object>>[];
      Future<void> save(String name, List<int> bytes) async {
        final file = File('${root.path}/$name');
        await file.parent.create(recursive: true);
        await file.create(exclusive: true);
        await file.writeAsBytes(bytes, flush: true);
        files.add({
          'name': name,
          'bytes': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        });
      }

      for (final name in [
        'ru-blocked.srs',
        'ru-blocked-community.srs',
        're-filter.srs',
        'ru.srs',
      ]) {
        await save('geo/$name', await File('assets/geo/$name').readAsBytes());
        geo[name] = 'geo/$name';
      }
      ProviderGeoBundle bundle(String scope, {bool other = false}) =>
          ProviderGeoBundle.fromJson({
            'schema': 1,
            'scope': scope * 64,
            'metadataDigest': '3' * 64,
            'groups': {
              'block': other
                  ? <Map<String, dynamic>>[]
                  : [
                      {
                        'domain': ['blocked.example.test'],
                      },
                    ],
              'proxy': [
                {
                  'domain': [
                    if (!other) 'blocked.example.test',
                    'proxy.example.test',
                    if (other) 'direct.example.test',
                  ],
                },
              ],
              'direct': other
                  ? <Map<String, dynamic>>[]
                  : [
                      {
                        'domain': [
                          'blocked.example.test',
                          'proxy.example.test',
                          'direct.example.test',
                        ],
                      },
                    ],
            },
          });
      final source = WindowsVpnDatasource(onStatusChanged: (_) {});
      final proxy = const VlessParser().parse(
        'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@192.0.2.10:443?security=none&type=tcp',
      );
      final cases = [
        (
          'provider-block',
          GeoRoutingMode.provider,
          RoutingMode.bypassRU,
          'blocked.example.test',
          'block',
          false,
        ),
        (
          'provider-proxy-priority',
          GeoRoutingMode.provider,
          RoutingMode.bypassRU,
          'proxy.example.test',
          'proxy',
          false,
        ),
        (
          'provider-direct',
          GeoRoutingMode.provider,
          RoutingMode.bypassRU,
          'direct.example.test',
          'direct',
          false,
        ),
        (
          'provider-final',
          GeoRoutingMode.provider,
          RoutingMode.bypassRU,
          'default.example.test',
          'proxy',
          false,
        ),
        (
          'provider-isolation',
          GeoRoutingMode.provider,
          RoutingMode.bypassRU,
          'direct.example.test',
          'proxy',
          true,
        ),
        (
          'combined-block',
          GeoRoutingMode.combined,
          RoutingMode.bypassRU,
          'blocked.example.test',
          'block',
          false,
        ),
        (
          'builtin-ru-ipv4',
          GeoRoutingMode.builtIn,
          RoutingMode.bypassRU,
          '2.16.20.1',
          'direct',
          false,
        ),
        (
          'builtin-ru-ipv6',
          GeoRoutingMode.builtIn,
          RoutingMode.bypassRU,
          '2001:470:5:5c::1',
          'proxy',
          false,
        ),
        (
          'global-ignores-provider',
          GeoRoutingMode.provider,
          RoutingMode.global,
          'blocked.example.test',
          'proxy',
          false,
        ),
        (
          'provider-doh',
          GeoRoutingMode.provider,
          RoutingMode.bypassRU,
          '203.0.113.53',
          'dns',
          false,
        ),
      ];
      final records = <Map<String, Object>>[];
      for (final row in cases) {
        final config = source.buildConfiguration(
          proxy,
          AppSettings(
            geoRoutingMode: row.$2,
            routingMode: row.$3,
            preferredIpType: IpType.ipv4,
            dnsPreset: DnsPreset.custom,
            customDnsUrl: 'https://127.0.0.1:19443/dns-query',
          ),
          mode: row.$5 == 'dns' ? ConnectionMode.tunnel : ConnectionMode.proxy,
          geoPaths: geo,
          providerRouting: bundle(row.$6 ? '2' : '1', other: row.$6),
        );
        await save('${row.$1}.json', utf8.encode(jsonEncode(config)));
        records.add({
          'id': row.$1,
          'file': '${row.$1}.json',
          'target': row.$4,
          'expected': row.$5,
        });
      }
      await File('${root.path}/manifest.json').writeAsString(
        jsonEncode({
          'schema': 1,
          'syntheticOnly': true,
          'files': files,
          'cases': records,
        }),
        flush: true,
      );
      expect(records, hasLength(10));
    },
    skip: output.isEmpty
        ? 'Explicit synthetic native probe export only'
        : false,
  );
}
