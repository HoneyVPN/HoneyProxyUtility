import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../../lib/features/converter/data/parsers/subscription_parser.dart';
import '../../../lib/features/converter/domain/entities/parsed_proxy.dart';

void main() {
  const parser = SubscriptionParser();

  test('URL-safe base64 with line wrapping is detected and decoded', () {
    // Unicode fragments ensure this encoded subscription exercises URL-safe '-'.
    const link =
        'vless://account@node.example.test:443?security=tls#\uFFFF\uFFFF';
    final encoded = base64Url.encode(utf8.encode(link)).replaceAll('=', '');
    expect(encoded, contains('-'));
    final wrapped = '${encoded.substring(0, 24)} \n${encoded.substring(24)}';
    expect(parser.detect(wrapped), SubscriptionFormat.v2ray);
    expect(parser.parse(wrapped).single.host, 'node.example.test');
  });

  test('UTF-8 BOM before proxy links does not drop the first node', () {
    expect(
      parser.parse('\uFEFFvless://account@node.example.test:443#Node'),
      hasLength(1),
    );
  });

  test('Clash Reality configuration with tls enabled retains Reality keys', () {
    final result =
        parser.parse('''
proxies:
  - name: Reality node
    type: vless
    server: node.example.test
    port: 443
    uuid: account
    tls: true
    servername: cover.example.test
    reality-opts:
      public-key: public-key
      short-id: abcd
''').single
            as VlessConfig;
    expect(result.security, 'reality');
    expect(result.publicKey, 'public-key');
    expect(result.shortId, 'abcd');
  });

  for (final (fields, expected) in [
    ('client-fingerprint: firefox', 'firefox'),
    ('fingerprint: safari', 'safari'),
    ('client-fingerprint: firefox\n    fingerprint: safari', 'firefox'),
  ]) {
    test('Clash VLESS retains browser fingerprint from $fields', () {
      final result =
          parser.parse('''
proxies:
  - name: Reality node
    type: vless
    server: node.example.test
    port: 443
    uuid: account
    tls: true
    servername: cover.example.test
    $fields
    reality-opts:
      public-key: public-key
      short-id: abcd
''').single
              as VlessConfig;
      expect(result.fingerprint, expected);
      expect(result.effectiveFingerprint, expected);
    });
  }

  test('one malformed Clash proxy does not discard subsequent valid nodes', () {
    final result = parser.parse('''
proxies:
  - name: [bad, type]
    type: vless
  - name: Valid
    type: vless
    server: node.example.test
    port: 443
    uuid: account
''');
    expect(result, hasLength(1));
    expect(result.single.name, 'Valid');
  });

  test(
    'one malformed sing-box outbound does not discard subsequent valid nodes',
    () {
      final result = parser.parse(
        jsonEncode({
          'outbounds': [
            {
              'type': ['bad'],
              'server': 'bad.example.test',
              'server_port': 443,
            },
            {
              'type': 'vless',
              'tag': 'Valid',
              'server': 'node.example.test',
              'server_port': 443,
              'uuid': 'account',
            },
          ],
        }),
      );
      expect(result, hasLength(1));
      expect(result.single.name, 'Valid');
    },
  );
}
