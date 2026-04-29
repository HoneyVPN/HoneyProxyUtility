import 'dart:convert';
import 'package:test/test.dart';

import '../../../lib/features/converter/data/parsers/vmess_parser.dart';
import '../../../lib/features/converter/data/parsers/base_parser.dart';
import '../../../lib/features/converter/domain/entities/parsed_proxy.dart';

void main() {
  const parser = VmessParser();

  group('VmessParser', () {
    test('parses standard vmess link', () {
      final payload = {
        'v': '2', 'ps': 'Test Server', 'add': 'example.com',
        'port': '443', 'id': 'a3482e88-686a-4a58-8126-99c9df64b7bf',
        'aid': '0', 'net': 'ws', 'type': 'none', 'path': '/ws',
        'host': 'cdn.example.com', 'tls': 'tls', 'sni': 'example.com', 'fp': 'chrome',
      };
      final b64 = base64.encode(utf8.encode(json.encode(payload)));
      final link = 'vmess://$b64';

      final result = parser.parse(link) as VmessConfig;
      expect(result.name, 'Test Server');
      expect(result.host, 'example.com');
      expect(result.port, 443);
      expect(result.uuid, 'a3482e88-686a-4a58-8126-99c9df64b7bf');
      expect(result.network, 'ws');
      expect(result.tls, 'tls');
      expect(result.fingerprint, 'chrome');
    });

    test('parses vmess with integer port', () {
      final payload = {'add': '1.2.3.4', 'port': 8080, 'id': 'test-uuid', 'aid': 0};
      final b64 = base64.encode(utf8.encode(json.encode(payload)));
      final result = parser.parse('vmess://$b64');
      expect(result.port, 8080);
    });

    test('parses vmess with string port', () {
      final payload = {'add': '1.2.3.4', 'port': '8443', 'id': 'test-uuid', 'aid': '0'};
      final b64 = base64.encode(utf8.encode(json.encode(payload)));
      final result = parser.parse('vmess://$b64');
      expect(result.port, 8443);
    });

    test('handles missing optional fields gracefully', () {
      final payload = {'add': '1.2.3.4', 'port': 443, 'id': 'uuid'};
      final b64 = base64.encode(utf8.encode(json.encode(payload)));
      final result = parser.parse('vmess://$b64');
      expect(result.name, '');
      expect(result.network, 'tcp');
      expect(result.tls, '');
      expect(result.security, 'auto');
    });

    test('throws ParseException on empty payload', () {
      expect(() => parser.parse('vmess://'), throwsA(isA<ParseException>()));
    });

    test('throws ParseException on invalid base64', () {
      expect(() => parser.parse('vmess://not!valid!base64!!!'), throwsA(isA<ParseException>()));
    });

    test('throws ParseException on missing host', () {
      final payload = {'port': 443, 'id': 'uuid'};
      final b64 = base64.encode(utf8.encode(json.encode(payload)));
      expect(() => parser.parse('vmess://$b64'), throwsA(isA<ParseException>()));
    });

    test('canParse returns true for vmess://', () {
      expect(parser.canParse('vmess://abc'), isTrue);
    });

    test('canParse returns false for non-vmess', () {
      expect(parser.canParse('vless://abc'), isFalse);
      expect(parser.canParse('ss://abc'), isFalse);
    });
  });
}
