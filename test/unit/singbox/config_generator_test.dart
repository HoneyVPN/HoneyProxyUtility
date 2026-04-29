import 'dart:convert';
import 'package:test/test.dart';

import '../../../lib/features/connection/data/singbox/singbox_config_generator.dart';
import '../../../lib/features/converter/domain/entities/parsed_proxy.dart';

void main() {
  const generator = SingboxConfigGenerator();
  const settings = AppSettings();

  group('SingboxConfigGenerator', () {
    test('generates valid JSON for VLESS+Reality', () {
      const proxy = VlessConfig(
        name: 'Test', host: 'example.com', port: 443,
        uuid: 'a3482e88-686a-4a58-8126-99c9df64b7bf',
        flow: 'xtls-rprx-vision', encryption: 'none',
        security: 'reality', sni: 'sni.com',
        fingerprint: 'chrome', publicKey: 'pubkey',
        shortId: 'abcd', spiderX: '',
        transport: 'tcp', path: '/',
        transportHost: '', grpcServiceName: '',
      );

      final configStr = generator.generate(proxy, settings);
      final config = json.decode(configStr) as Map<String, dynamic>;

      expect(config['log'], isNotNull);
      expect(config['inbounds'], isA<List>());
      expect(config['outbounds'], isA<List>());
      expect(config['route'], isNotNull);
      expect(config['dns'], isNotNull);

      final outbound = (config['outbounds'] as List).first as Map<String, dynamic>;
      expect(outbound['type'], 'vless');
      expect(outbound['server'], 'example.com');
      expect(outbound['uuid'], 'a3482e88-686a-4a58-8126-99c9df64b7bf');
      expect(outbound['flow'], 'xtls-rprx-vision');

      final tls = outbound['tls'] as Map<String, dynamic>;
      expect(tls['enabled'], isTrue);
      expect(tls['reality']['enabled'], isTrue);
      expect(tls['reality']['public_key'], 'pubkey');
    });

    test('generates valid JSON for Hysteria2', () {
      const proxy = Hysteria2Config(
        name: 'HY2', host: '1.2.3.4', port: 443,
        auth: 'myauth', sni: 'sni.com', insecure: false,
        obfs: '', obfsPassword: '', pinSha256: '',
      );
      final config = json.decode(generator.generate(proxy, settings)) as Map<String, dynamic>;
      final out = (config['outbounds'] as List).first as Map<String, dynamic>;
      expect(out['type'], 'hysteria2');
      expect(out['password'], 'myauth');
      expect((out['tls'] as Map)['enabled'], isTrue);
    });

    test('generates valid JSON for TUIC', () {
      const proxy = TuicConfig(
        name: 'TUIC', host: 'host.com', port: 443,
        uuid: 'test-uuid', password: 'pass', sni: 'host.com',
        alpn: 'h3', congestionControl: 'bbr',
        udpRelayMode: 'native', allowInsecure: false,
      );
      final config = json.decode(generator.generate(proxy, settings)) as Map<String, dynamic>;
      final out = (config['outbounds'] as List).first as Map<String, dynamic>;
      expect(out['type'], 'tuic');
      expect(out['congestion_control'], 'bbr');
    });

    test('generates valid JSON for Shadowsocks', () {
      const proxy = ShadowsocksConfig(
        name: 'SS', host: 'ss.host.com', port: 8388,
        method: 'chacha20-ietf-poly1305', password: 'pass',
        plugin: '', pluginOpts: '',
      );
      final config = json.decode(generator.generate(proxy, settings)) as Map<String, dynamic>;
      final out = (config['outbounds'] as List).first as Map<String, dynamic>;
      expect(out['type'], 'shadowsocks');
      expect(out['method'], 'chacha20-ietf-poly1305');
    });

    test('always includes direct, block, dns outbounds', () {
      const proxy = VlessConfig(
        name: '', host: 'h', port: 443, uuid: 'u',
        flow: '', encryption: 'none', security: 'none',
        sni: '', fingerprint: '', publicKey: '', shortId: '',
        spiderX: '', transport: 'tcp', path: '/',
        transportHost: '', grpcServiceName: '',
      );
      final config = json.decode(generator.generate(proxy, settings)) as Map<String, dynamic>;
      final outbounds = (config['outbounds'] as List).map((o) => (o as Map)['tag']).toList();
      expect(outbounds, containsAll(['proxy', 'direct', 'block', 'dns-out']));
    });

    test('TUN inbound has correct address', () {
      const proxy = ShadowsocksConfig(name: '', host: 'h', port: 8388, method: 'aes-256-gcm', password: 'p', plugin: '', pluginOpts: '');
      final config = json.decode(generator.generate(proxy, settings)) as Map<String, dynamic>;
      final inbounds = config['inbounds'] as List;
      final tun = inbounds.firstWhere((i) => (i as Map)['type'] == 'tun') as Map;
      expect((tun['address'] as List).contains('172.19.0.1/30'), isTrue);
    });

    test('generates WS transport block for VMess+WS', () {
      const proxy = VmessConfig(
        name: '', host: 'h', port: 443, uuid: 'u', alterId: 0,
        security: 'auto', network: 'ws', path: '/path',
        wsHost: 'cdn.com', tls: 'tls', sni: 'h', alpn: '', fingerprint: '',
      );
      final config = json.decode(generator.generate(proxy, settings)) as Map<String, dynamic>;
      final out = (config['outbounds'] as List).first as Map<String, dynamic>;
      expect(out['transport']['type'], 'ws');
      expect(out['transport']['path'], '/path');
    });

    test('generates route with CN bypass rules', () {
      const s = AppSettings(routingMode: RoutingMode.bypassCN);
      const proxy = ShadowsocksConfig(name: '', host: 'h', port: 8388, method: 'aes-256-gcm', password: 'p', plugin: '', pluginOpts: '');
      final config = json.decode(generator.generate(proxy, s)) as Map<String, dynamic>;
      final rules = (config['route']['rules'] as List).map((r) => (r as Map)).toList();
      expect(rules.any((r) => r['rule_set'] == 'geosite-cn'), isTrue);
      expect(rules.any((r) => r['rule_set'] == 'geoip-cn'), isTrue);
    });
  });
}
