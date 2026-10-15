import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/base_parser.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';

String config({String endpoint = 'vpn.example.com:51820', String extra = ''}) =>
    '''
# Name: 🇩🇪 Germany
[Interface]
PrivateKey = private-key
Address = 10.0.0.2/32
$extra
[Peer]
PublicKey = public-key
Endpoint = $endpoint
''';

void main() {
  const dispatcher = LinkDispatcher();
  test('imports a complete commented config once and preserves its name', () {
    final servers = dispatcher.dispatchMultiple('\uFEFF${config()}');
    expect(servers, hasLength(1));
    expect(servers.single, isA<WireGuardConfig>());
    expect(servers.single.name, '🇩🇪 Germany');
    expect(servers.single.host, 'vpn.example.com');
  });
  test('recognizes commented AWG and preserves obfuscation parameters', () {
    final server = dispatcher.dispatch(config(extra: 'Jc = 7\nS3 = 12'));
    expect(server, isA<AmneziaWGConfig>());
    expect((server as AmneziaWGConfig).jc, 7);
    expect(server.s3, 12);
  });
  test('supports bracketed IPv6 endpoints', () {
    final server = dispatcher.dispatch(config(endpoint: '[2001:db8::1]:51820'));
    expect(server.host, '2001:db8::1');
    expect(server.port, 51820);
  });

  test('preserves explicit port 443 and defaults URI ports to 51820', () {
    for (final endpoint in ['vpn.example.com:443', '[2001:db8::1]:443']) {
      expect(dispatcher.dispatch(config(endpoint: endpoint)).port, 443);
    }
    expect(
      dispatcher
          .dispatch('wireguard://vpn.example.com?privateKey=a&publicKey=b')
          .port,
      51820,
    );
    expect(
      dispatcher
          .dispatch('awg://vpn.example.com?privateKey=a&publicKey=b')
          .port,
      51820,
    );
  });
  test('rejects incomplete blocks rather than creating phantom servers', () {
    expect(
      () => dispatcher.dispatch('[Interface]'),
      throwsA(isA<ParseException>()),
    );
    expect(
      () => dispatcher.dispatchMultiple('[Interface]\n[Peer]'),
      throwsA(isA<ParseException>()),
    );
    expect(
      () => dispatcher.dispatch(config(endpoint: '')),
      throwsA(isA<ParseException>()),
    );
    expect(
      () => dispatcher.dispatch(config(endpoint: 'vpn.example.com:70000')),
      throwsA(isA<ParseException>()),
    );
  });
}
