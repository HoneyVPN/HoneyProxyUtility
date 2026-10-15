import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/builders/apple_config_builder.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/vpn_datasource_windows.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/provider_geo_bundle.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/provider_geo_dat_decoder.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/singbox_config_generator.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/provider_routing_parser.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/vless_parser.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/subscriptions/domain/entities/provider_geo_state.dart';
import 'package:honeyproxyutility/features/subscriptions/domain/entities/provider_routing_metadata.dart';

ProviderRoutingMetadata _metadata(
  Map<String, Object?> profile, {
  int id = 17,
}) => const ProviderRoutingParser()
    .parse(
      subscriptionId: id,
      body:
          'happ://routing/add/' +
          base64.encode(utf8.encode(jsonEncode(profile))),
    )
    .metadata;
ProviderGeoBundle _compile(
  ProviderRoutingMetadata metadata, {
  Uint8List? site,
  Uint8List? ip,
  String url = 'https://provider.example.test/feed',
  ProviderGeoCompiler compiler = const ProviderGeoCompiler(),
}) => compiler.compile(
  metadata.commands.single.profile!,
  scope: providerGeoScope(metadata.subscriptionId, url),
  metadataDigest: providerMetadataDigest(metadata),
  geoSite: site,
  geoIp: ip,
);

List<int> _varint(int value) {
  final result = <int>[];
  do {
    final byte = value & 127;
    value >>= 7;
    result.add(byte | (value == 0 ? 0 : 128));
  } while (value != 0);
  return result;
}

List<int> _bytes(int field, List<int> bytes) => [
  ..._varint(field * 8 + 2),
  ..._varint(bytes.length),
  ...bytes,
];

Uint8List _sites(
  Map<String, List<String>> categories, {
  List<String> attributes = const [],
}) => Uint8List.fromList([
  for (final entry in categories.entries)
    ..._bytes(1, [
      ..._bytes(1, utf8.encode(entry.key)),
      for (final domain in entry.value)
        ..._bytes(2, [
          8,
          3,
          ..._bytes(2, utf8.encode(domain)),
          for (final attribute in attributes)
            ..._bytes(3, _bytes(1, utf8.encode(attribute))),
        ]),
    ]),
]);

Uint8List _ips(String category) => Uint8List.fromList(
  _bytes(1, [
    ..._bytes(1, utf8.encode(category)),
    ..._bytes(2, [10, 4, 192, 0, 2, 0, 16, 24]),
  ]),
);

List<String> _caseVariants(String category) => [
  for (var mask = 0; mask < 1 << category.length; mask++)
    [
      for (var index = 0; index < category.length; index++)
        (mask & (1 << index)) == 0
            ? category[index]
            : category[index].toUpperCase(),
    ].join(),
];

final _proxy = const VlessParser().parse(
  'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@192.0.2.10:443?security=none&type=tcp',
);
final _geoPaths = {
  for (final name in [
    'ru-blocked.srs',
    'ru-blocked-community.srs',
    're-filter.srs',
    'ru.srs',
  ])
    name: File('assets/geo/$name').absolute.path,
};
Map<String, dynamic> _config(
  String target,
  AppSettings settings,
  ProviderGeoBundle? bundle,
) => switch (target) {
  'android' =>
    jsonDecode(
          SingboxConfigGenerator(
            geoPaths: _geoPaths,
            providerRouting: bundle,
          ).generateForAndroid(_proxy, settings),
        )
        as Map<String, dynamic>,
  'apple' =>
    jsonDecode(
          AppleConfigBuilder(
            geoPaths: _geoPaths,
            providerRouting: bundle,
          ).generate(_proxy, settings),
        )
        as Map<String, dynamic>,
  _ => WindowsVpnDatasource(onStatusChanged: (_) {}).buildConfiguration(
    _proxy,
    settings,
    geoPaths: _geoPaths,
    providerRouting: bundle,
    mode: target == 'windowsTunnel'
        ? ConnectionMode.tunnel
        : ConnectionMode.proxy,
  ),
};
final _representative = _metadata({
  'Name': 'Representative',
  'DirectSites': ['domain:local.example.test'],
  'DirectIp': ['!192.0.2.0/24', '!198.51.100.0/24', '203.0.113.19'],
  'ProxySites': ['full:proxy.example.test'],
  'BlockSites': [r'regexp:^ads\.example\.test$'],
});
final _bundle = _compile(_representative);

void _checkAndExport(String name, String target, Map<String, dynamic> config) {
  final output = Platform.environment['PROVIDER_GEO_CONFIG_OUTPUT_DIR'] ?? '';
  Directory? temporary;
  final dir =
      output.isEmpty
            ? (temporary = Directory.systemTemp.createTempSync('pgeo-check-'))
            : Directory(output)
        ..createSync(recursive: true);
  try {
    final file = File('${dir.path}/$name.json')
      ..writeAsStringSync(jsonEncode(config));
    final binary =
        Platform.environment[target == 'apple'
            ? 'PROVIDER_GEO_APPLE_CHECK_BINARY'
            : 'PROVIDER_GEO_CHECK_BINARY'] ??
        '';
    if (binary.isNotEmpty) {
      final environment = Map<String, String>.from(Platform.environment)
        ..removeWhere((key, _) => key.startsWith('ENABLE_DEPRECATED_'));
      final result = Process.runSync(
        binary,
        ['check', '-c', file.path],
        environment: environment,
        includeParentEnvironment: false,
      );
      expect(result.exitCode, 0, reason: '$name: ${result.stderr}');
    }
  } finally {
    temporary?.deleteSync(recursive: true);
  }
}

void main() {
  for (final ip in [false, true]) {
    test(
      '2048 ${ip ? 'geoip' : 'geosite'} category case variants consume one selection',
      () {
        const category = 'abcdefghijk';
        final variants = _caseVariants(category);
        expect(variants, hasLength(2048));
        final metadata = _metadata({
          if (ip)
            'DirectIp': [
              for (final value in variants) 'geoip:$value',
              '!geoip:$category',
            ]
          else
            'DirectSites': [for (final value in variants) 'geosite:$value'],
        });
        final bundle = _compile(
          metadata,
          site: ip
              ? null
              : _sites({
                  category: ['one.invalid'],
                }),
          ip: ip ? _ips(category) : null,
          compiler: const ProviderGeoCompiler(
            datLimits: ProviderGeoDatLimits(maxSelectedRecords: 1),
          ),
        );
        final rules = bundle.groups['direct']!;
        if (ip) {
          expect(rules, [
            {
              'ip_cidr': ['192.0.2.0/24'],
            },
            {
              'ip_cidr': ['192.0.2.0/24'],
              'invert': true,
            },
          ]);
        } else {
          expect(rules.single['domain'], ['one.invalid']);
        }
      },
    );
  }

  for (final attributes in [false, true]) {
    test(
      'distinct ${attributes ? 'attribute' : 'category'} selections reject cumulative DAT work',
      () {
        final metadata = _metadata({
          'DirectSites': attributes
              ? ['geosite:a@Ads', 'geosite:a@ads']
              : ['geosite:a', 'geosite:b'],
        });
        expect(
          () => _compile(
            metadata,
            site: _sites(
              {
                'a': ['same.invalid'],
                'b': ['same.invalid'],
              },
              attributes: ['Ads', 'ads'],
            ),
            compiler: const ProviderGeoCompiler(
              datLimits: ProviderGeoDatLimits(maxSelectedRecords: 1),
            ),
          ),
          throwsA(
            isA<ProviderGeoException>().having(
              (error) => error.issue,
              'issue',
              ProviderGeoIssue.tooLarge,
            ),
          ),
        );
      },
    );
  }

  test(
    'aggregate role output stops at the string limit before later expansion',
    () {
      final input = _sites({
        'a': [for (var n = 0; n < 15001; n++) '$n.test'],
      });
      expect(
        () => _compile(
          _metadata({
            'BlockSites': ['geosite:a'],
            'ProxySites': ['geosite:a'],
            'DirectSites': ['geosite:missing'],
          }),
          site: input,
        ),
        throwsA(
          isA<ProviderGeoException>().having(
            (error) => error.issue,
            'issue',
            ProviderGeoIssue.tooLarge,
          ),
        ),
      );
    },
  );

  test(
    'IP inverse selectors are one AND clause with positive OR alternative',
    () {
      final rows = _bundle.groups['direct']!;
      final positive = rows.singleWhere(
        (row) => row.containsKey('ip_cidr') && row['invert'] != true,
      );
      final negative = rows.singleWhere((row) => row['invert'] == true);
      expect(positive['ip_cidr'], ['203.0.113.19/32']);
      expect(negative['ip_cidr'], ['192.0.2.0/24', '198.51.100.0/24']);
      expect(rows.length, 3); // Domain union, positive IP, inverse union.
    },
  );
  test('namespaced immutable bundle changes with subscription and content', () {
    final other = _compile(
      _metadata(_representative.commands.single.profile!.toJson(), id: 18),
    );
    expect(other.tag('direct'), isNot(_bundle.tag('direct')));
    final changed = _compile(
      _metadata({
        'DirectSites': ['full:new.example.test'],
      }),
    );
    expect(changed.tag('direct'), isNot(_bundle.tag('direct')));
    expect(() => _bundle.groups['direct']!.clear(), throwsUnsupportedError);
    expect(
      () => (_bundle.groups['direct']!.first['domain'] as List).clear(),
      throwsUnsupportedError,
    );
    expect(
      ProviderGeoBundle.fromJson(
        jsonDecode(jsonEncode(_bundle.toJson())),
      ).digest,
      _bundle.digest,
    );
  });
  for (final bad in [
    'bad_name.example',
    '-bad.example',
    'bad-.example',
    '${'a' * 64}.example',
    '.full.example',
  ]) {
    test('stored bundle rejects native-incompatible domain $bad', () {
      expect(
        () => ProviderGeoBundle.fromJson({
          ..._bundle.toJson(),
          'groups': {
            'block': [],
            'proxy': [],
            'direct': [
              {
                'domain': [bad],
              },
            ],
          },
        }),
        throwsA(isA<ProviderGeoException>()),
      );
    });
  }
  test(
    'canonical CIDRs mask host bits and reject ambiguous textual addresses',
    () {
      expect(canonicalProviderCidr('192.0.2.99/24'), '192.0.2.0/24');
      expect(canonicalProviderCidr('2001:db8:0:0::1/32'), '2001:db8::/32');
      for (final bad in [
        '127.1',
        '010.0.0.1',
        '192.0.2.0/024',
        'fe80::1%en0/64',
      ]) {
        expect(
          () => canonicalProviderCidr(bad),
          throwsA(isA<ProviderGeoException>()),
        );
      }
    },
  );
  test('oversized bundle is rejected before crossing native RPC', () {
    expect(
      () => _compile(
        _metadata({
          'DirectSites': ['keyword:${'a' * 513}'],
        }),
      ),
      throwsA(
        isA<ProviderGeoException>().having(
          (e) => e.issue,
          'issue',
          ProviderGeoIssue.tooLarge,
        ),
      ),
    );
  });
  for (final target in ['android', 'windowsTunnel', 'windowsProxy', 'apple']) {
    for (final mode in [GeoRoutingMode.provider, GeoRoutingMode.combined]) {
      test(
        '$target ${mode.name} preserves manual DNS/guards and ordered provider policy',
        () {
          final settings = AppSettings(
            geoRoutingMode: mode,
            dnsPreset: DnsPreset.custom,
            customDnsUrl: 'https://dns.example.test/query',
          );
          final config = _config(target, settings, _bundle);
          final before = _config(
            target,
            settings.copyWith(geoRoutingMode: GeoRoutingMode.builtIn),
            null,
          );
          expect(config['dns'], before['dns']);
          expect(config['inbounds'], before['inbounds']);
          expect(config['outbounds'], before['outbounds']);
          final route = config['route'] as Map;
          final rules = (route['rules'] as List).cast<Map>();
          int index(String tag) =>
              rules.indexWhere((r) => r['rule_set'] == tag);
          expect(
            index(_bundle.tag('block')),
            lessThan(index(_bundle.tag('proxy'))),
          );
          expect(
            index(_bundle.tag('proxy')),
            lessThan(index(_bundle.tag('direct'))),
          );
          expect(rules.first['action'], 'sniff');
          expect(
            rules.indexWhere((r) => r['ip_is_private'] == true),
            lessThan(index(_bundle.tag('block'))),
          );
          if (mode == GeoRoutingMode.combined) {
            expect(index('ru-blocked'), lessThan(index(_bundle.tag('direct'))));
            expect(
              rules.indexWhere(
                (r) => r['rule_set'] == 'ru' && r['outbound'] == 'direct',
              ),
              greaterThan(index(_bundle.tag('direct'))),
            );
          } else {
            expect(rules.any((r) => r['rule_set'] == 'ru'), false);
          }
          final refs = rules
              .where((r) => r['rule_set'] == _bundle.tag('direct'))
              .toList();
          expect(refs.length, target == 'android' ? 2 : 1);
          if (target == 'android') expect(refs.first['ip_version'], 6);
          _checkAndExport('$target-providerGeo-${mode.name}', target, config);
        },
      );
    }
    test('$target builtin and global configuration stay byte-equivalent', () {
      for (final mode in [RoutingMode.global, RoutingMode.bypassRU]) {
        final s = AppSettings(routingMode: mode);
        expect(
          jsonEncode(_config(target, s, _bundle)),
          jsonEncode(_config(target, s, null)),
        );
      }
      final global = const AppSettings(routingMode: RoutingMode.global);
      expect(
        _config(
          target,
          global.copyWith(geoRoutingMode: GeoRoutingMode.provider),
          null,
        ),
        _config(target, global, null),
      );
      const combined = AppSettings(geoRoutingMode: GeoRoutingMode.combined);
      expect(
        _config(target, combined, null),
        _config(target, const AppSettings(), null),
      );
      expect(
        () => _config(
          target,
          const AppSettings(geoRoutingMode: GeoRoutingMode.provider),
          null,
        ),
        throwsA(isA<ProviderGeoException>()),
      );
    });
  }
  final fixtureDir =
      Platform.environment['PROVIDER_GEO_PUBLIC_FIXTURE_DIR'] ?? '';
  if (fixtureDir.isNotEmpty) {
    test('whole official three-role profile fits the practical inline budget', () {
      final site = File('$fixtureDir/dlc.dat').readAsBytesSync();
      final ip = File('$fixtureDir/geoip.dat').readAsBytesSync();
      expect(
        providerGeoHash(site),
        '51fcbfa2bf420e678a4c1f764ad8b2e668f99ac95fae147bb7aea7f75f96a641',
      );
      expect(
        providerGeoHash(ip),
        '4ff4b2ec242a9e87b296ba27ddb85f8311e8d3e071eaebac5be9231c60e408dd',
      );
      final bundle = _compile(
        _metadata({
          'Geoipurl':
              'https://github.com/v2fly/geoip/releases/download/202610050438/geoip.dat',
          'Geositeurl':
              'https://github.com/v2fly/domain-list-community/releases/download/20261009101206/dlc.dat',
          'ProxySites': ['geosite:google'],
          'BlockSites': ['geosite:category-ads-all'],
          'DirectIp': ['geoip:ru'],
          'RouteOrder': 'block-proxy-direct',
          'UseChunkFiles': 'true',
        }),
        site: site,
        ip: ip,
      );
      final inline = utf8
          .encode(
            jsonEncode({
              'rule_set': bundle.ruleSets,
              'rules': [
                ...bundle.rulesFor('block'),
                ...bundle.rulesFor('proxy'),
                ...bundle.rulesFor('direct'),
              ],
            }),
          )
          .length;
      final configs = <String, Object?>{};
      for (final target in ['android', 'windowsTunnel', 'apple']) {
        final config = _config(
          target,
          const AppSettings(geoRoutingMode: GeoRoutingMode.combined),
          bundle,
        );
        _checkAndExport('$target-providerGeo-real-three-role', target, config);
        configs[target] = {
          'configBytes': utf8.encode(jsonEncode(config)).length,
        };
      }
      final strings = bundle.groups.values
          .expand((rows) => rows)
          .expand(
            (row) => row.entries
                .where((entry) => entry.value is List)
                .expand((entry) => entry.value as List),
          )
          .length;
      File('$fixtureDir/three-role-measurement.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'compiledStrings': strings,
          'inlineBytes': inline,
          'bundleDigest': bundle.digest,
          'configs': configs,
        }),
      );
      expect(strings, 26407);
      expect(inline, lessThan(ProviderGeoBundle.maximumInlineBytes));
    });
    test(
      'official pinned DAT categories decode, compile and pass real core check',
      () {
        final site = File('$fixtureDir/dlc.dat').readAsBytesSync();
        final ip = File('$fixtureDir/geoip.dat').readAsBytesSync();
        expect(
          providerGeoHash(site),
          '51fcbfa2bf420e678a4c1f764ad8b2e668f99ac95fae147bb7aea7f75f96a641',
        );
        expect(
          providerGeoHash(ip),
          '4ff4b2ec242a9e87b296ba27ddb85f8311e8d3e071eaebac5be9231c60e408dd',
        );
        final measurements = <Map<String, Object?>>[];
        for (final category in [
          'google',
          'geolocation-ru',
          'ru',
          'category-ads-all',
          'geolocation-!cn',
        ]) {
          final row = <String, Object?>{
            'kind': 'geosite',
            'category': category,
          };
          try {
            final decoded = const ProviderGeoDatDecoder().decodeGeoSite(
              site,
              category: category,
            );
            row['rawStrings'] = decoded.rules.length;
            row['rawUTF8Bytes'] = decoded.rules.fold<int>(
              0,
              (n, r) => n + utf8.encode(r.value).length,
            );
            final bundle = _compile(
              _metadata({
                'ProxySites': ['geosite:$category'],
              }),
              site: site,
            );
            row['compiledStrings'] = bundle.groups.values
                .expand((rows) => rows)
                .expand(
                  (r) => r.entries
                      .where((e) => e.value is List)
                      .expand((e) => e.value as List),
                )
                .length;
            row['inlineBytes'] = utf8
                .encode(
                  jsonEncode({
                    'rule_set': bundle.ruleSets,
                    'rules': [
                      ...bundle.rulesFor('block'),
                      ...bundle.rulesFor('proxy'),
                      ...bundle.rulesFor('direct'),
                    ],
                  }),
                )
                .length;
            row['bundleDigest'] = bundle.digest;
            row['supported'] = true;
            for (final target in ['android', 'windowsTunnel', 'apple']) {
              _checkAndExport(
                '$target-providerGeo-real-$category',
                target,
                _config(
                  target,
                  const AppSettings(geoRoutingMode: GeoRoutingMode.combined),
                  bundle,
                ),
              );
            }
          } catch (e) {
            row['supported'] = false;
            row['issue'] = e.toString();
          }
          measurements.add(row);
        }
        for (final category in ['ru', 'cn']) {
          final row = <String, Object?>{'kind': 'geoip', 'category': category};
          try {
            final decoded = const ProviderGeoDatDecoder().decodeGeoIp(
              ip,
              category: category,
            );
            row['rawStrings'] = decoded.cidrs.length;
            row['rawUTF8Bytes'] = decoded.cidrs.fold<int>(
              0,
              (n, r) => n + utf8.encode(r.cidr).length,
            );
            final bundle = _compile(
              _metadata({
                'DirectIp': ['geoip:$category'],
              }),
              ip: ip,
            );
            row['inlineBytes'] = utf8
                .encode(
                  jsonEncode({
                    'rule_set': bundle.ruleSets,
                    'rules': bundle.rulesFor('direct'),
                  }),
                )
                .length;
            row['bundleDigest'] = bundle.digest;
            row['supported'] = true;
            for (final target in ['android', 'windowsTunnel', 'apple']) {
              _checkAndExport(
                '$target-providerGeo-real-ip-$category',
                target,
                _config(
                  target,
                  const AppSettings(geoRoutingMode: GeoRoutingMode.combined),
                  bundle,
                ),
              );
            }
          } catch (e) {
            row['supported'] = false;
            row['issue'] = e.toString();
          }
          measurements.add(row);
        }
        File('$fixtureDir/category-measurements.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(measurements),
        );
        expect(
          measurements.firstWhere(
            (row) => row['category'] == 'google',
          )['supported'],
          true,
        );
        expect(
          measurements.firstWhere(
            (row) => row['kind'] == 'geoip' && row['category'] == 'ru',
          )['supported'],
          true,
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
