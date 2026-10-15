import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../../lib/features/converter/data/parsers/base_parser.dart';
import '../../../lib/features/converter/data/parsers/link_dispatcher.dart';
import '../../../lib/features/converter/data/parsers/subscription_parser.dart';
import '../../../lib/features/converter/domain/entities/parsed_proxy.dart';

const _id = 'a3482e88-686a-4a58-8126-99c9df64b7bf';
const _vless = 'vless://$_id@192.0.2.10:443';
const _hy2 = 'hy2://fake-password@192.0.2.10:443';

void main() {
  const dispatcher = LinkDispatcher();
  final key = base64Url
      .encode(List.generate(32, (i) => i + 1))
      .replaceAll('=', '');
  final encryption = 'mlkem768x25519plus.native.0rtt.$key';

  test(
    'preserves VLESS Encryption, explicit TLS options and literal path escapes',
    () {
      final proxy =
          dispatcher.dispatch(
                '$_vless?security=tls&type=ws&'
                'path=%2F%252F%25literal&alpn=h2%2Chttp%2F1.1&allowInsecure=1&'
                'encryption=$encryption',
              )
              as VlessConfig;
      expect(proxy.encryption, encryption);
      expect(proxy.path, '/%2F%literal');
      expect(proxy.alpn, ['h2', 'http/1.1']);
      expect(proxy.allowInsecure, isTrue);
      expect(
        (dispatcher.dispatch(_vless) as VlessConfig).allowInsecure,
        isFalse,
      );
      expect((dispatcher.dispatch(_vless) as VlessConfig).encryption, 'none');
    },
  );

  test(
    'normalizes raw and WebSocket aliases without dropping connection options',
    () {
      expect(
        (dispatcher.dispatch('$_vless?type=raw') as VlessConfig).transport,
        'tcp',
      );
      expect(
        (dispatcher.dispatch('$_vless?type=websocket') as VlessConfig)
            .transport,
        'ws',
      );
    },
  );

  test(
    'rejects known unsupported VLESS features before import without leaking values',
    () {
      for (final query in [
        'type=kcp',
        'type=quic',
        'type=hysteria',
        'security=xtls',
        'flow=xtls-rprx-vision-udp443',
        'flow=xtls-rprx-direct',
        'flow=xtls-rprx-vision&security=none',
        'flow=xtls-rprx-vision&security=tls&type=ws',
        'headerType=http',
        'type=xhttp&extra=SECRET-VALUE',
        'ech=SECRET-VALUE',
        'pqv=SECRET-VALUE',
        'type=ws&ed=2048',
        'security=reality&spx=%2Funsupported-path',
        'encryption=unsupported-SECRET-VALUE',
        'encryption=mlkem768x25519plus.native.0rtt.100-111-1111.$key',
      ]) {
        expect(
          () => dispatcher.dispatch('$_vless?$query'),
          throwsA(
            isA<UnsupportedConfigurationException>().having(
              (e) => e.toString(),
              'safe reason',
              isNot(contains('SECRET-VALUE')),
            ),
          ),
          reason: query.split('=').first,
        );
      }
      expect(
        dispatcher.dispatch('$_vless?utm_source=opaque&remark=metadata'),
        isA<VlessConfig>(),
      );
      expect(
        dispatcher.dispatch('$_vless?security=reality&spx=%2F'),
        isA<VlessConfig>(),
      );
    },
  );

  test(
    'Hysteria2 IPv6 hopping and percent-encoded userpass auth are preserved once',
    () {
      final proxy =
          dispatcher.dispatch(
                'hysteria2://user%3Ap%40ss%252F@[2001:db8::10]:443,5000-5002/?'
                'sni=node.example.test&hopInterval=30s',
              )
              as Hysteria2Config;
      expect(proxy.host, '2001:db8::10');
      expect(proxy.port, 443);
      expect(proxy.auth, 'user:p@ss%2F');
      expect(proxy.serverPorts, ['443:443', '5000:5002']);
      expect(
        (dispatcher.dispatch('$_hy2?ports=443,5000-5002') as Hysteria2Config)
            .serverPorts,
        proxy.serverPorts,
      );
      expect(proxy.hopInterval, '30s');
      final noAuth =
          dispatcher.dispatch('hy2://192.0.2.10:5000-5002') as Hysteria2Config;
      expect(noAuth.serverPorts, ['5000:5002']);
    },
  );

  test(
    'Hysteria2 mport validates bounds and rejects conflicting authorities',
    () {
      final proxy =
          dispatcher.dispatch('$_hy2?mport=443,5000-5002') as Hysteria2Config;
      expect(proxy.serverPorts, ['443:443', '5000:5002']);
      for (final ports in ['0', '65536', '5002-5000', '443,', '-1', 'bad']) {
        expect(
          () => dispatcher.dispatch('$_hy2?mport=$ports'),
          throwsA(isA<UnsupportedConfigurationException>()),
        );
      }
      expect(
        () => dispatcher.dispatch('hy2://192.0.2.10:5000-5002?mport=6000-6002'),
        throwsA(isA<UnsupportedConfigurationException>()),
      );
    },
  );

  test('Hysteria2 certificate pin and newer core features fail explicitly', () {
    for (final query in [
      'pinSHA256=SECRET-FINGERPRINT',
      'obfs=gecko',
      'ech=SECRET',
      'maxHopInterval=30s',
      'hopInterval=0s',
    ]) {
      expect(
        () => dispatcher.dispatch('$_hy2?$query'),
        throwsA(
          isA<UnsupportedConfigurationException>().having(
            (e) => e.toString(),
            'safe reason',
            isNot(contains('SECRET')),
          ),
        ),
      );
    }
  });

  test(
    'URI, base64, Clash and sing-box subscriptions abort a mixed unsupported feed',
    () {
      final badLink = '$_hy2?pinSHA256=SECRET-FINGERPRINT';
      final lines = '$_vless\n$badLink';
      const parser = SubscriptionParser();
      for (final body in [
        lines,
        base64Encode(utf8.encode(lines)),
        '''
proxies:
  - {type: vless, server: 192.0.2.10, port: 443, uuid: $_id}
  - {type: hysteria2, server: 192.0.2.10, port: 443, pinSHA256: SECRET-FINGERPRINT}
''',
        jsonEncode({
          'outbounds': [
            {
              'type': 'vless',
              'server': '192.0.2.10',
              'server_port': 443,
              'uuid': _id,
            },
            {
              'type': 'hysteria2',
              'server': '192.0.2.10',
              'server_port': 443,
              'tls': {
                'pinned_peer_certificate_chain_sha256': ['SECRET-FINGERPRINT'],
              },
            },
          ],
        }),
      ]) {
        expect(
          () => parser.parse(body),
          throwsA(isA<UnsupportedConfigurationException>()),
        );
      }
    },
  );

  test(
    'known Hysteria1 and realm links never disappear from a mixed feed silently',
    () {
      for (final unsupported in [
        'hysteria://fake@192.0.2.10:443',
        'hysteria2+realm://fake@192.0.2.10/realm-name',
      ]) {
        expect(
          () => dispatcher.dispatchMultiple('$_vless\n$unsupported'),
          throwsA(isA<UnsupportedConfigurationException>()),
        );
      }
      for (final body in [
        'proxies:\n  - {type: hysteria, server: 192.0.2.10, port: 443}',
        jsonEncode({
          'outbounds': [
            {'type': 'hysteria', 'server': '192.0.2.10', 'server_port': 443},
          ],
        }),
      ]) {
        expect(
          () => const SubscriptionParser().parse(body),
          throwsA(isA<UnsupportedConfigurationException>()),
        );
      }
    },
  );

  test(
    'recognized Amnezia 3.1 flags and advanced fields cannot be silently skipped in a subscription',
    () {
      for (final parameter in [
        'RandomTrailers=on',
        'DisableCookies=true',
        'I1=synthetic-signature',
        'H1=1-10',
      ]) {
        final link =
            'awg://192.0.2.10:51820?privatekey=fake&publickey=fake&$parameter';
        expect(
          () => dispatcher.dispatchMultiple('$_vless\n$link'),
          throwsA(isA<UnsupportedConfigurationException>()),
        );
      }
      expect(
        dispatcher.dispatch(
          'awg://192.0.2.10:51820?privatekey=fake&publickey=fake&RandomTrailers=off&DisableCookies=false',
        ),
        isA<AmneziaWGConfig>(),
      );
    },
  );

  test(
    'Clash and sing-box imports preserve encryption, hopping, auth and TLS options',
    () {
      const parser = SubscriptionParser();
      final clash = parser.parse('''
proxies:
  - type: vless
    server: 192.0.2.10
    port: 443
    uuid: $_id
    encryption: $encryption
    tls: true
    alpn: [h2, http/1.1]
    skip-cert-verify: true
  - type: hysteria2
    server: 192.0.2.10
    port: 443
    password: user:fake-password
    ports: 443,5000-5002
    hop-interval: 30
''');
      final vless = clash.first as VlessConfig;
      final hy2 = clash.last as Hysteria2Config;
      expect(vless.encryption, encryption);
      expect(vless.alpn, ['h2', 'http/1.1']);
      expect(vless.allowInsecure, isTrue);
      expect(hy2.auth, 'user:fake-password');
      expect(hy2.serverPorts, ['443:443', '5000:5002']);
      expect(hy2.hopInterval, '30s');
      final json = parser.parse(
        jsonEncode({
          'outbounds': [
            {
              'type': 'vless',
              'server': '192.0.2.10',
              'server_port': 443,
              'uuid': _id,
              'encryption': encryption,
              'tls': {
                'enabled': true,
                'alpn': ['h2'],
                'insecure': true,
              },
              'transport': {
                'type': 'http',
                'host': ['node.example.test'],
                'path': '/%2F',
              },
            },
            {
              'type': 'hysteria2',
              'server': '192.0.2.10',
              'server_port': 443,
              'password': 'user:fake-password',
              'server_ports': ['443:443', '5000:5002'],
              'hop_interval': '30s',
            },
          ],
        }),
      );
      expect((json.first as VlessConfig).encryption, encryption);
      expect((json.first as VlessConfig).path, '/%2F');
      expect((json.first as VlessConfig).transportHost, 'node.example.test');
      expect((json.last as Hysteria2Config).serverPorts, hy2.serverPorts);
    },
  );
}
