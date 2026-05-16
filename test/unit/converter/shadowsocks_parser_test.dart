import 'dart:convert';
import 'package:test/test.dart';

import '../../../lib/features/converter/data/parsers/shadowsocks_parser.dart';
import '../../../lib/features/converter/domain/entities/parsed_proxy.dart';

void main() {
  const parser = ShadowsocksParser();

  group('ShadowsocksParser — SIP002', () {
    test('parses standard SIP002 link', () {
      // ss://BASE64(aes-256-gcm:password)@example.com:8388#Server
      final userInfo = base64.encode(utf8.encode('aes-256-gcm:my_password'));
      final link = 'ss://$userInfo@example.com:8388#Test%20Server';
      final r = parser.parse(link) as ShadowsocksConfig;
      expect(r.method, 'aes-256-gcm');
      expect(r.password, 'my_password');
      expect(r.host, 'example.com');
      expect(r.port, 8388);
      expect(r.name, 'Test Server');
    });

    test('parses SIP002 with obfs plugin', () {
      final userInfo = base64.encode(utf8.encode('chacha20-ietf-poly1305:pass'));
      final link = 'ss://$userInfo@1.2.3.4:443?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com#Obfs';
      final r = parser.parse(link) as ShadowsocksConfig;
      expect(r.plugin, 'obfs-local');
      expect(r.method, 'chacha20-ietf-poly1305');
    });
  });

  group('ShadowsocksParser — Legacy', () {
    test('parses legacy ss:// link', () {
      // ss://BASE64(method:password@host:port)#name
      final payload = base64.encode(utf8.encode('aes-128-gcm:supersecret@192.168.1.1:1080'));
      final link = 'ss://$payload#Legacy';
      final r = parser.parse(link) as ShadowsocksConfig;
      expect(r.method, 'aes-128-gcm');
      expect(r.password, 'supersecret');
      expect(r.host, '192.168.1.1');
      expect(r.port, 1080);
      expect(r.name, 'Legacy');
    });
  });

  group('ShadowsocksParser — SS2022', () {
    test('parses SS2022 with percent-encoded userinfo', () {
      // SS2022 uses percent-encoded key directly
      final link = 'ss://2022-blake3-aes-256-gcm:base64key%3D%3D@host.com:8388#SS2022';
      final r = parser.parse(link) as ShadowsocksConfig;
      expect(r.method, '2022-blake3-aes-256-gcm');
      expect(r.host, 'host.com');
    });
  });

  test('canParse returns true for ss://', () {
    expect(parser.canParse('ss://abc'), isTrue);
    expect(parser.canParse('vmess://abc'), isFalse);
  });
}
