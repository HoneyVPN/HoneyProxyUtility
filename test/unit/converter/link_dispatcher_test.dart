import 'dart:convert';
import 'package:test/test.dart';

import '../../../lib/features/converter/data/parsers/link_dispatcher.dart';
import '../../../lib/features/converter/data/parsers/base_parser.dart';
import '../../../lib/features/converter/domain/entities/parsed_proxy.dart';

void main() {
  const dispatcher = LinkDispatcher();

  group('LinkDispatcher', () {
    test('dispatches vmess:// to VmessConfig', () {
      final payload = {'add': '1.2.3.4', 'port': 443, 'id': 'uuid'};
      final b64 = base64.encode(utf8.encode(json.encode(payload)));
      final result = dispatcher.dispatch('vmess://$b64');
      expect(result, isA<VmessConfig>());
    });

    test('dispatches vless:// to VlessConfig', () {
      const link = 'vless://uuid@host.com:443?security=tls#Test';
      final result = dispatcher.dispatch(link);
      expect(result, isA<VlessConfig>());
    });

    test('dispatches trojan:// to TrojanConfig', () {
      const link = 'trojan://password@host.com:443?security=tls#Trojan';
      final result = dispatcher.dispatch(link);
      expect(result, isA<TrojanConfig>());
    });

    test('dispatches ss:// to ShadowsocksConfig', () {
      final userInfo = base64.encode(utf8.encode('aes-256-gcm:pass'));
      final result = dispatcher.dispatch('ss://$userInfo@1.2.3.4:8388#SS');
      expect(result, isA<ShadowsocksConfig>());
    });

    test('dispatches hy2:// to Hysteria2Config', () {
      const link = 'hy2://auth@host.com:443#HY2';
      final result = dispatcher.dispatch(link);
      expect(result, isA<Hysteria2Config>());
    });

    test('dispatches tuic:// to TuicConfig', () {
      const link = 'tuic://uuid:password@host.com:443?sni=host.com#TUIC';
      final result = dispatcher.dispatch(link);
      expect(result, isA<TuicConfig>());
    });

    test('throws UnsupportedProtocolException for unknown scheme', () {
      expect(() => dispatcher.dispatch('http://example.com'), throwsA(isA<UnsupportedProtocolException>()));
    });

    test('throws ParseException for empty input', () {
      expect(() => dispatcher.dispatch(''), throwsA(isA<ParseException>()));
    });

    test('dispatchMultiple skips bad lines and returns good ones', () {
      final payload = {'add': '1.2.3.4', 'port': 443, 'id': 'uuid'};
      final b64 = base64.encode(utf8.encode(json.encode(payload)));
      final text = '''
vmess://$b64
this_is_invalid
vless://uuid@host.com:443?security=tls#Test
''';
      final results = dispatcher.dispatchMultiple(text);
      expect(results.length, 2);
      expect(results[0], isA<VmessConfig>());
      expect(results[1], isA<VlessConfig>());
    });

    test('trims whitespace before dispatching', () {
      const link = '  vless://uuid@host.com:443?security=tls#Test  ';
      final result = dispatcher.dispatch(link);
      expect(result, isA<VlessConfig>());
    });
  });
}
