import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../../lib/features/converter/data/parsers/provider_routing_parser.dart';
import '../../../lib/features/converter/data/parsers/subscription_parser.dart';
import '../../../lib/features/settings/data/models/app_settings.dart';
import '../../../lib/features/subscriptions/domain/entities/provider_routing_metadata.dart';

const _proxy =
    'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@node.example.invalid:443?security=tls#Synthetic';
const _profile = <String, Object?>{
  'Name': 'Example provider',
  'GlobalProxy': 'true',
  'FakeDNS': 'false',
  'DomainStrategy': 'IPIfNonMatch',
  'RemoteDNSType': 'DoH',
  'RemoteDNSDomain': 'https://dns.example.invalid/dns-query',
  'RemoteDNSIP': '192.0.2.53',
  'Geoipurl': 'https://geo.example.invalid/geoip.dat',
  'Geositeurl': 'https://geo.example.invalid/geosite.dat',
  'LastUpdated': '1700000000',
  'DnsHosts': {'dns.example.invalid': '192.0.2.53'},
  'DirectSites': ['full:status.example.invalid', 'domain:example.invalid'],
  'ProxySites': [
    'geosite:geolocation-!cn@!cn',
    'keyword:synthetic',
    'regexp:^test\\.',
  ],
  'BlockSites': ['geosite:ads', 'dotless:printer-'],
  'DirectIp': [
    '!geoip:cn',
    '!geoip:us',
    'geoip:telegram',
    '192.0.2.0/24',
    '2001:db8::/32',
  ],
  'ProxyIp': ['::ffff:192.0.2.1', '198.51.100.2'],
  'BlockIp': [],
};

String _link(
  Map<String, Object?> profile, {
  String op = 'onadd',
  bool urlSafe = false,
}) {
  final bytes = utf8.encode(jsonEncode(profile));
  final encoded = urlSafe
      ? base64Url.encode(bytes).replaceAll('=', '')
      : base64.encode(bytes);
  return 'happ://routing/$op/$encoded';
}

Matcher issue(ProviderRoutingIssue value) =>
    isA<ProviderRoutingParseException>().having(
      (e) => e.issue,
      'safe issue',
      value,
    );

void main() {
  const parser = ProviderRoutingParser();
  test(
    'Remnawave Happ aliases and supported priority survive canonical persistence',
    () {
      final original = <String, Object?>{
        'GeoipUrl': 'https://geo.example.invalid/ip.dat',
        'GeositeUrl': 'https://geo.example.invalid/site.dat',
        'FakeDns': 'false',
        'RemoteDNSIp': '192.0.2.53',
        'RouteOrder': 'block-proxy-direct',
        'useChunkFiles': 'true',
        'DirectIp': ['geoip:ru'],
      };
      final parsed = parser
          .parse(subscriptionId: 17, body: _link(original))
          .metadata;
      final profile = parsed.commands.single.profile!;
      expect(profile.geoIpUrl, original['GeoipUrl']);
      expect(profile.geoSiteUrl, original['GeositeUrl']);
      expect(profile.declarations.preferChunkFiles, true);
      expect(profile.declarations.routeOrder, 'block-proxy-direct');
      expect(profile.declarations.dns['RemoteDNSIP'], '192.0.2.53');
      expect(profile.declarations.fakeDns, false);
      expect(original.containsKey('GeoipUrl'), true);
      expect(original.containsKey('Geoipurl'), false);
      expect(
        parser.parseStored(parsed.toJson(), subscriptionId: 17).toJson(),
        parsed.toJson(),
      );
    },
  );
  test(
    'unsupported route order and conflicting alias URLs fail without choosing data',
    () {
      for (final profile in <Map<String, Object?>>[
        {'RouteOrder': 'direct-proxy-block'},
        {
          'Geoipurl': 'https://geo.example.invalid/a.dat',
          'GeoipUrl': 'https://geo.example.invalid/b.dat',
        },
        {
          'UseChunkFiles': {'unexpected': true},
        },
      ]) {
        expect(
          () => parser.parse(subscriptionId: 1, body: _link(profile)),
          throwsA(issue(ProviderRoutingIssue.schema)),
        );
      }
    },
  );
  test(
    'HTTP header is case insensitive and standalone body preserves proxy parsing',
    () {
      final a = parser.parse(
        subscriptionId: 1,
        body: _proxy,
        headers: {
          'RoUtInG': [_link(_profile)],
        },
      );
      final b = parser.parse(
        subscriptionId: 1,
        body: '${_link(_profile)}\r\n$_proxy',
      );
      expect(a.metadata.toJson(), b.metadata.toJson());
      expect(a.proxyBody, _proxy);
      expect(b.proxyBody, _proxy);
      expect(
        const SubscriptionParser().parse(b.proxyBody).single.host,
        'node.example.invalid',
      );
    },
  );

  test(
    'BOM, wrapped URL-safe base64 feed and nested routing payload decode separately',
    () {
      final body = '\uFEFF${_link(_profile, urlSafe: true)}\n$_proxy';
      final raw = base64Url.encode(utf8.encode(body)).replaceAll('=', '');
      final wrapped = '\uFEFF${raw.substring(0, 48)} \r\n${raw.substring(48)}';
      final envelope = parser.parse(subscriptionId: 2, body: wrapped);
      expect(envelope.base64BodyDecoded, isTrue);
      expect(envelope.proxyBody, _proxy);
      expect(
        envelope.metadata.commands.single.profile!.name,
        'Example provider',
      );
    },
  );

  test(
    'identical header/body command is deduplicated but add/onadd/off remain distinct',
    () {
      final link = _link(_profile);
      final envelope = parser.parse(
        subscriptionId: 3,
        headers: {
          'routing': [link],
        },
        body:
            '$link\n${_link(_profile, op: 'add')}\nhapp://routing/off\n$_proxy',
      );
      expect(envelope.metadata.commands.map((c) => c.operation), [
        ProviderRoutingOperation.onadd,
        ProviderRoutingOperation.add,
        ProviderRoutingOperation.off,
      ]);
      expect(envelope.metadata.commands.last.profile, isNull);
    },
  );

  test('DNS/global/fake DNS declarations do not mutate manual settings', () {
    const settings = AppSettings(
      routingMode: RoutingMode.global,
      dnsPreset: DnsPreset.custom,
      customDnsUrl: 'https://manual.example.invalid:8443/dns-query',
      enableFakeip: true,
    );
    final before = settings.toJson();
    final profile = parser
        .parse(subscriptionId: 4, body: _link(_profile))
        .metadata
        .commands
        .single
        .profile!;
    expect(profile.declarations.globalProxy, isTrue);
    expect(profile.declarations.fakeDns, isFalse);
    expect(
      profile.declarations.dns['RemoteDNSDomain'],
      'https://dns.example.invalid/dns-query',
    );
    expect(settings.toJson(), before);
  });

  test(
    'positive and negative IP selectors retain grouping inputs without flattening',
    () {
      final profile = parser
          .parse(subscriptionId: 5, body: _link(_profile))
          .metadata
          .commands
          .single
          .profile!;
      expect(profile.directIp.take(3).map((r) => (r.value, r.negated)), [
        ('cn', true),
        ('us', true),
        ('telegram', false),
      ]);
      expect(profile.directIp[4].kind, ProviderRuleKind.ipNetwork);
      expect(profile.proxyIp.first.value, '::ffff:192.0.2.1');
      final site = profile.proxySites.first;
      expect(site.kind, ProviderRuleKind.geoSite);
      expect(site.value, 'geolocation-!cn');
      expect(site.attribute, '!cn');
      expect(profile.proxySites.last.kind, ProviderRuleKind.regularExpression);
    },
  );

  test(
    'two subscription scopes persist separately and foreign stored scope rejects',
    () {
      final a = parser
          .parse(subscriptionId: 10, body: _link(_profile))
          .metadata;
      final b = parser
          .parse(subscriptionId: 20, body: 'happ://routing/off')
          .metadata;
      expect(a.subscriptionId, 10);
      expect(b.subscriptionId, 20);
      final restored = parser.parseStored(
        jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>,
        subscriptionId: 10,
      );
      expect(restored.toJson(), a.toJson());
      expect(
        () => parser.parseStored(a.toJson(), subscriptionId: 20),
        throwsA(issue(ProviderRoutingIssue.scope)),
      );
      expect(() => a.commands.clear(), throwsUnsupportedError);
      expect(
        () => a.commands.single.profile!.directIp.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => a.commands.single.profile!.declarations.dns.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'multiple GeoSite attributes retain literal keys, including ! prefix',
    () {
      final profile = parser
          .parse(
            subscriptionId: 1,
            body: _link({
              'ProxySites': ['geosite:google@cn@!ads'],
            }),
          )
          .metadata
          .commands
          .single
          .profile!;
      expect(profile.proxySites.single.value, 'google');
      expect(profile.proxySites.single.attribute, 'cn@!ads');
      expect(profile.proxySites.single.negated, isFalse);
      expect(profile.toJson()['ProxySites'], ['geosite:google@cn@!ads']);
    },
  );

  test(
    'ordinary base64 proxy, Clash and sing-box bodies remain byte identical',
    () {
      for (final body in [
        base64.encode(utf8.encode(_proxy)),
        'proxies:\n  - name: synthetic',
        '{"outbounds":[],"route":{"final":"proxy"}}',
      ]) {
        final envelope = parser.parse(subscriptionId: 1, body: body);
        expect(envelope.proxyBody, body);
        expect(envelope.metadata.commands, isEmpty);
        expect(envelope.base64BodyDecoded, isFalse);
      }
    },
  );

  test(
    'empty/default fields do not invent geo URLs, name or provider preferences',
    () {
      final profile = parser
          .parse(
            subscriptionId: 1,
            body: _link({
              'Geoipurl': '',
              'Geositeurl': '',
              'LastUpdated': '',
              'RemoteDns': '',
              'DomesticDns': '',
            }),
          )
          .metadata
          .commands
          .single
          .profile!;
      expect(profile.geoIpUrl, isNull);
      expect(profile.geoSiteUrl, isNull);
      expect(profile.name, isNull);
      expect(profile.lastUpdatedUnix, isNull);
      expect(profile.declarations.globalProxy, isNull);
      expect(profile.declarations.dns, isEmpty);
    },
  );

  test(
    'URI-encoded profile payload preserves asset query without network work',
    () {
      final link = _link({
        ..._profile,
        'Geoipurl':
            'https://geo.example.invalid:8443/geoip.dat?token=SYNTHETIC%2FVALUE',
      });
      final encoded =
          'happ://routing/onadd/${Uri.encodeComponent(link.substring('happ://routing/onadd/'.length))}';
      final profile = parser
          .parse(subscriptionId: 1, body: encoded)
          .metadata
          .commands
          .single
          .profile!;
      expect(
        profile.geoIpUrl,
        'https://geo.example.invalid:8443/geoip.dat?token=SYNTHETIC%2FVALUE',
      );
    },
  );

  for (final raw in [
    '{"Name":"A","Name":"B"}',
    '{"Name":"A","\\u004eame":"B"}',
    '{"DnsHosts":{"dns.example.invalid":"192.0.2.1","dns.example.invalid":"192.0.2.2"}}',
    '${'[' * 18}0${']' * 18}',
    '{"Name":',
  ]) {
    test(
      'duplicate/nested/malformed JSON rejects without exposing payload',
      () {
        final link = 'happ://routing/add/${base64.encode(utf8.encode(raw))}';
        expect(
          () => parser.parse(subscriptionId: 1, body: link),
          throwsA(issue(ProviderRoutingIssue.json)),
        );
      },
    );
  }

  for (final link in [
    'happ://routing/add/%xx',
    'happ://routing/add/%%%SECRET',
    'happ://routing/add/_w==',
    'happ://routing/off?global=true',
    'happ://routing/unknown/AA==',
    '${_link(_profile)}#fragment',
  ]) {
    test('malformed routing link rejects with safe code', () {
      try {
        parser.parse(subscriptionId: 1, body: link);
        fail('Expected typed routing rejection');
      } on ProviderRoutingParseException catch (e) {
        expect(e.toString(), matches(r'^providerRouting:[a-z]+$'));
        expect(e.toString(), isNot(contains('SECRET')));
        expect(e.toString(), isNot(contains('happ://')));
      }
    });
  }

  for (final fields in <Map<String, Object?>>[
    {
      'DirectSites': ['geosite:'],
    },
    {
      'DirectSites': ['geosite:!cn'],
    },
    {
      'DirectIp': ['geoip:_invalid'],
    },
    {
      'DirectSites': ['ext:private.dat:ru'],
    },
    {
      'DirectSites': ['domain:bad/name'],
    },
    {
      'DirectSites': ['dotless:has.dot'],
    },
    {
      'DirectIp': ['geoip:!cn'],
    },
    {
      'DirectIp': ['192.0.2.0/33'],
    },
    {
      'DirectIp': ['2001:db8::/129'],
    },
    {
      'DirectIp': ['2001:::1'],
    },
    {
      'DirectIp': ['192.0.2.999'],
    },
    {
      'DirectIp': ['2001:db8::%zone'],
    },
    {
      'DirectIp': ['!ext:private.dat:ru'],
    },
    {'ProxyIp': 'geoip:cn'},
    {'GlobalProxy': 1},
    {'FakeDNS': 'sometimes'},
    {'LastUpdated': -1},
    {'LastUpdated': '9007199254740992'},
    {'Name': 'Secret\nvalue'},
    {
      'DnsHosts': {'dns.example.invalid': 'not-an-ip'},
    },
    {'Script': 'do-not-execute'},
    {'Geoipurl': 'file:///secret.dat'},
    {'Geoipurl': 'https://geo.example.invalid:/geoip.dat'},
    {'Geoipurl': 'https://geo.example.invalid/geoip.dat?bad=%wrong'},
    {'Geositeurl': 'https://user:SECRET@geo.example.invalid/geosite.dat'},
  ]) {
    test(
      'invalid/unsupported profile ${fields.keys.single} rejects atomically',
      () {
        expect(
          () => parser.parse(subscriptionId: 1, body: _link(fields)),
          throwsA(isA<ProviderRoutingParseException>()),
        );
      },
    );
  }

  test('ambiguous routing headers and excess payload/rules are bounded', () {
    expect(
      () => parser.parse(
        subscriptionId: 1,
        body: _link({
          'ProxySites': ['geosite:google@${'a' * 128}@b'],
        }),
      ),
      throwsA(issue(ProviderRoutingIssue.rule)),
    );
    expect(
      () => parser.parse(
        subscriptionId: 1,
        body: '',
        headers: {
          'routing': ['happ://routing/off\r\nInjected: value'],
        },
      ),
      throwsA(issue(ProviderRoutingIssue.link)),
    );
    expect(
      () => parser.parse(
        subscriptionId: 1,
        body: List.generate(
          ProviderRoutingParser.maximumCommands + 1,
          (i) => _link({'Name': 'Synthetic $i'}),
        ).join('\n'),
      ),
      throwsA(issue(ProviderRoutingIssue.size)),
    );
    expect(
      () => parser.parse(
        subscriptionId: 1,
        body: '',
        headers: {
          'routing': ['happ://routing/off'],
          'Routing': ['happ://routing/off'],
        },
      ),
      throwsA(issue(ProviderRoutingIssue.schema)),
    );
    expect(
      () => parser.parse(
        subscriptionId: 1,
        body: '',
        headers: {
          'routing': ['happ://routing/off', 'happ://routing/off'],
        },
      ),
      throwsA(issue(ProviderRoutingIssue.schema)),
    );
    expect(
      () => parser.parse(subscriptionId: 0, body: ''),
      throwsA(issue(ProviderRoutingIssue.scope)),
    );
    expect(
      () => parser.parse(
        subscriptionId: 1,
        body: 'x' * (ProviderRoutingParser.maximumBodyBytes + 1),
      ),
      throwsA(issue(ProviderRoutingIssue.size)),
    );
    expect(
      () => parser.parse(
        subscriptionId: 1,
        body: _link({'Name': 'x' * ProviderRoutingParser.maximumProfileBytes}),
      ),
      throwsA(issue(ProviderRoutingIssue.size)),
    );
    expect(
      () => parser.parse(
        subscriptionId: 1,
        body: _link({
          'DirectIp': List.filled(ProviderRoutingParser.maximumRules + 1, '::'),
        }),
      ),
      throwsA(issue(ProviderRoutingIssue.size)),
    );
  });
}
