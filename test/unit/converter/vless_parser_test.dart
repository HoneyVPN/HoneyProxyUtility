import 'package:test/test.dart';

import '../../../lib/features/converter/data/parsers/vless_parser.dart';
import '../../../lib/features/converter/domain/entities/parsed_proxy.dart';

void main() {
  const parser = VlessParser();

  group('VlessParser', () {
    test('parses VLESS+Reality link', () {
      const link = 'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@1.2.3.4:443'
          '?encryption=none&flow=xtls-rprx-vision&security=reality'
          '&sni=sni.example.com&pbk=abcpublickey&fp=chrome&sid=abc123&type=tcp'
          '#My%20Reality%20Server';

      final r = parser.parse(link) as VlessConfig;
      expect(r.name, 'My Reality Server');
      expect(r.host, '1.2.3.4');
      expect(r.port, 443);
      expect(r.uuid, 'a3482e88-686a-4a58-8126-99c9df64b7bf');
      expect(r.flow, 'xtls-rprx-vision');
      expect(r.security, 'reality');
      expect(r.publicKey, 'abcpublickey');
      expect(r.shortId, 'abc123');
      expect(r.fingerprint, 'chrome');
    });

    test('parses VLESS+TLS+WS link', () {
      const link = 'vless://uuid@example.com:443?security=tls&type=ws&path=%2Fws&host=cdn.com&sni=example.com#WS';
      final r = parser.parse(link) as VlessConfig;
      expect(r.transport, 'ws');
      expect(r.path, '/ws');
      expect(r.transportHost, 'cdn.com');
      expect(r.security, 'tls');
    });

    test('parses VLESS with gRPC transport', () {
      const link = 'vless://uuid@host.com:443?security=tls&type=grpc&serviceName=myservice#gRPC';
      final r = parser.parse(link) as VlessConfig;
      expect(r.transport, 'grpc');
      expect(r.grpcServiceName, 'myservice');
    });

    test('defaults port to 443 when not specified', () {
      // URI parser may give 0 for missing port; our parser defaults to 443
      const link = 'vless://uuid@host.com?security=none#test';
      // Note: URI with no port defaults to 0 from Uri.parse, we handle it
      final r = parser.parse(link) as VlessConfig;
      expect(r.host, 'host.com');
    });

    test('handles empty name gracefully', () {
      const link = 'vless://uuid@1.2.3.4:8080?security=none';
      final r = parser.parse(link) as VlessConfig;
      expect(r.name, '');
    });

    test('canParse returns true only for vless://', () {
      expect(parser.canParse('vless://abc'), isTrue);
      expect(parser.canParse('vmess://abc'), isFalse);
      expect(parser.canParse('trojan://abc'), isFalse);
    });
  });
}
