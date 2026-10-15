import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/subscription_parser.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/widgets/server_connection_label.dart';

const _uuid = 'a3482e88-686a-4a58-8126-99c9df64b7bf';
const _base = 'vless://$_uuid@server.example.invalid:443';

ServerProfileModel _profile(String configJson, {String protocol = 'vless'}) =>
    ServerProfileModel(
      id: 1,
      protocol: protocol,
      name: 'Public fixture',
      host: 'server.example.invalid',
      port: 443,
      configJson: configJson,
      subscriptionId: '',
      addedAt: DateTime(2026),
    );

String _storedLabel(String link) =>
    ServerConnectionLabel.fromProfile(_profile(jsonEncode({'rawLink': link})));

void main() {
  test('saved VLESS XHTTP Reality shows typed transport and security only', () {
    final label = _storedLabel(
      '$_base?type=xhttp&security=reality&fp=ios&mode=auto'
      '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=00#Finland',
    );
    expect(label, 'VLESS · XHTTP · REALITY');
    for (final privateField in [
      _uuid,
      'server.example.invalid',
      'AAAAAAAA',
      'ios',
    ]) {
      expect(label, isNot(contains(privateField)));
    }
  });

  test('WebSocket TLS and unencrypted TCP remain distinct', () {
    expect(
      _storedLabel('$_base?type=ws&security=tls&path=%2Fws'),
      'VLESS · WebSocket · TLS',
    );
    expect(_storedLabel('$_base?type=tcp&security=none'), 'VLESS · TCP');
  });

  test('other actual VLESS transport names retain their meaning', () {
    for (final entry in {
      'grpc': 'gRPC',
      'h2': 'HTTP/2',
      'http': 'HTTP/2',
      'httpupgrade': 'HTTPUpgrade',
    }.entries) {
      expect(
        _storedLabel('$_base?type=${entry.key}&security=tls'),
        'VLESS · ${entry.value} · TLS',
      );
    }
  });

  test('VMess cipher never masquerades as TLS or Reality', () {
    String link({
      required String cipher,
      required String tls,
      String net = 'tcp',
    }) {
      final payload = jsonEncode({
        'add': 'server.example.invalid',
        'port': '443',
        'id': _uuid,
        'scy': cipher,
        'net': net,
        'tls': tls,
      });
      return 'vmess://${base64Encode(utf8.encode(payload))}';
    }

    expect(_storedLabel(link(cipher: 'tls', tls: '')), 'VMess · TCP');
    expect(_storedLabel(link(cipher: 'auto', tls: 'reality')), 'VMess · TCP');
    expect(
      _storedLabel(link(cipher: 'chacha20-poly1305', tls: 'tls', net: 'ws')),
      'VMess · WebSocket · TLS',
    );
  });

  test('Trojan parser TLS defaults are actual typed defaults', () {
    expect(
      _storedLabel('trojan://fake-password@server.example.invalid:443?type=ws'),
      'Trojan · WebSocket · TLS',
    );
  });

  test(
    'native JSON subscription retains nested transport and Reality fields',
    () {
      final parsed = const SubscriptionParser().parse(
        jsonEncode({
          'outbounds': [
            {
              'type': 'vless',
              'tag': 'Public fixture',
              'server': 'server.example.invalid',
              'server_port': 443,
              'uuid': _uuid,
              'transport': {'type': 'xhttp', 'path': '/', 'mode': 'auto'},
              'tls': {
                'enabled': true,
                'reality': {
                  'enabled': true,
                  'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                  'short_id': '00',
                },
              },
            },
          ],
        }),
      );
      expect(parsed, hasLength(1));
      expect(
        ServerConnectionLabel.fromProxy(parsed.single),
        'VLESS · XHTTP · REALITY',
      );
    },
  );

  test('unknown nested cache JSON does not manufacture TCP or TLS', () {
    final cached = _profile(
      jsonEncode({
        'nested': {'transport': 'ws', 'security': 'tls'},
        'tls': {'enabled': true},
        'protocol': 'vless',
      }),
    );
    expect(ServerConnectionLabel.fromProfile(cached), 'VLESS');
  });

  test(
    'malformed and unsupported cached profiles keep only known protocol',
    () {
      expect(ServerConnectionLabel.fromProfile(_profile('{invalid')), 'VLESS');
      expect(ServerConnectionLabel.fromProfile(_profile('{}')), 'VLESS');
      expect(_storedLabel('$_base?type=kcp&security=tls'), 'VLESS');
      expect(
        ServerConnectionLabel.fromProfile(_profile('{}', protocol: 'secret')),
        isEmpty,
      );
    },
  );

  test('Shadowsocks obfs TLS string does not imply a TLS connection', () {
    final auth = base64Encode(utf8.encode('aes-128-gcm:fake-password'));
    expect(
      _storedLabel(
        'ss://$auth@server.example.invalid:443?plugin=obfs-local%3Bobfs%3Dtls',
      ),
      'SS',
    );
  });

  test('ShadowTLS shows its outer layer, not the inner VLESS transport', () {
    final inner = const LinkDispatcher().dispatch(
      '$_base?type=ws&security=tls',
    );
    final outer = ShadowTlsConfig(
      name: 'Public fixture',
      host: 'outer.example.invalid',
      port: 443,
      password: 'fake-password',
      sni: 'tls.example.invalid',
      version: 3,
      innerProxy: inner,
    );
    expect(ServerConnectionLabel.fromProxy(outer), 'ShadowTLS · TCP · TLS');
  });

  test('QUIC protocols do not acquire a fictitious TCP transport', () {
    expect(
      _storedLabel('hy2://fake-password@server.example.invalid:443'),
      'Hy2 · QUIC · TLS',
    );
    expect(
      _storedLabel('tuic://$_uuid:fake-password@server.example.invalid:443'),
      'TUIC · QUIC · TLS',
    );
  });
}
