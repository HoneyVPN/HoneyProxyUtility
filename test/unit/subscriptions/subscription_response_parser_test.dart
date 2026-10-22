import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../../lib/features/converter/data/parsers/base_parser.dart';
import '../../../lib/features/converter/data/parsers/subscription_response_parser.dart';

const _proxy = 'vless://test@node.example.invalid:443?security=tls#Synthetic';

void main() {
  const parser = SubscriptionResponseParser();

  test(
    'worker transfers decoded profiles and provider routing together',
    () async {
      final routing =
          'happ://routing/onadd/${base64.encode(utf8.encode(jsonEncode({
            'Name': 'Provider',
            'DirectSites': ['domain:example.invalid'],
          })))}';
      final parsed = await parser.parse(
        subscriptionId: 7,
        body: base64.encode(utf8.encode('$routing\n$_proxy')),
      );

      expect(parsed.proxies.single.host, 'node.example.invalid');
      expect(parsed.envelope!.base64BodyDecoded, isTrue);
      expect(parsed.envelope!.metadata.subscriptionId, 7);
      expect(
        parsed.envelope!.metadata.commands.single.profile!.name,
        'Provider',
      );
      expect(parsed.routingParseFailed, isFalse);
    },
  );

  test(
    'invalid optional provider rules preserve an otherwise valid feed',
    () async {
      final parsed = await parser.parse(
        subscriptionId: 7,
        body: _proxy,
        headers: {
          'RoUtInG': ['happ://routing/onadd/not-valid-base64'],
        },
      );

      expect(parsed.proxies.single.host, 'node.example.invalid');
      expect(parsed.envelope, isNull);
      expect(parsed.routingParseFailed, isTrue);
      expect(parsed.routingDeclared, isTrue);
    },
  );

  test(
    'worker preserves error types used by refresh failure classification',
    () async {
      await expectLater(
        parser.parse(subscriptionId: 1, body: 'invalid response'),
        throwsA(isA<ParseException>()),
      );
      await expectLater(
        parser.parse(
          subscriptionId: 1,
          body: '$_proxy\nhysteria://test@node.example.invalid:443',
        ),
        throwsA(isA<UnsupportedConfigurationException>()),
      );
    },
  );

  test(
    'metadata adoption skips proxy parsing for an already selected import',
    () async {
      final parsed = await parser.parse(
        subscriptionId: 7,
        body: 'not a proxy feed',
        includeProxies: false,
        headers: {
          'routing': ['happ://routing/off'],
        },
      );

      expect(parsed.proxies, isEmpty);
      expect(parsed.envelope!.metadata.commands, hasLength(1));
      expect(parsed.routingParseFailed, isFalse);
    },
  );
}
