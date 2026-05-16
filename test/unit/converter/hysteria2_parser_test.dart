import 'package:test/test.dart';

import '../../../lib/features/converter/data/parsers/hysteria2_parser.dart';
import '../../../lib/features/converter/domain/entities/parsed_proxy.dart';

void main() {
  const parser = Hysteria2Parser();

  group('Hysteria2Parser', () {
    test('parses hy2:// link', () {
      const link = 'hy2://mypassword@server.example.com:443?sni=sni.example.com&insecure=0#HY2%20Server';
      final r = parser.parse(link) as Hysteria2Config;
      expect(r.auth, 'mypassword');
      expect(r.host, 'server.example.com');
      expect(r.port, 443);
      expect(r.sni, 'sni.example.com');
      expect(r.insecure, isFalse);
      expect(r.name, 'HY2 Server');
    });

    test('parses hysteria2:// long form', () {
      const link = 'hysteria2://pass@1.2.3.4:8080?insecure=1#Test';
      final r = parser.parse(link) as Hysteria2Config;
      expect(r.insecure, isTrue);
      expect(r.host, '1.2.3.4');
      expect(r.port, 8080);
    });

    test('parses hy2 with obfs salamander', () {
      const link = 'hy2://auth@host.com:443?obfs=salamander&obfs-password=gawrgura#Obfs';
      final r = parser.parse(link) as Hysteria2Config;
      expect(r.obfs, 'salamander');
      expect(r.obfsPassword, 'gawrgura');
    });

    test('parses hy2 with port hopping range', () {
      const link = 'hy2://auth@host.com:5000-6000?sni=sni.com#Hopping';
      final r = parser.parse(link) as Hysteria2Config;
      expect(r.host, 'host.com');
      expect(r.port, 5000);
      expect(r.ports, '5000-6000');
    });

    test('canParse recognises both hy2:// and hysteria2://', () {
      expect(parser.canParse('hy2://abc'), isTrue);
      expect(parser.canParse('hysteria2://abc'), isTrue);
      expect(parser.canParse('vmess://abc'), isFalse);
    });
  });
}
