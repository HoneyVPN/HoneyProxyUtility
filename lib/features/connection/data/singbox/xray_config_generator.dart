import 'dart:convert';

import '../../../converter/domain/entities/parsed_proxy.dart';

/// Converts a [ParsedProxy] to an XRay-core JSON configuration string
/// for use with [FlutterV2ray.startV2Ray].
///
/// Supported: VMess, VLESS, Trojan, Shadowsocks.
/// Others throw [UnsupportedError].
class XrayConfigGenerator {
  const XrayConfigGenerator();

  String generate(ParsedProxy proxy) {
    final outbound = _outbound(proxy);
    final config = {
      'log': {'loglevel': 'error', 'access': '', 'error': ''},
      'dns': {
        'servers': ['8.8.8.8', '8.8.4.4', '1.1.1.1'],
      },
      'inbounds': [
        {
          'tag': 'in_proxy',
          'protocol': 'socks',
          'port': 1080,
          'listen': '127.0.0.1',
          'settings': {'auth': 'noauth', 'udp': true},
          'sniffing': {'enabled': true, 'destOverride': ['http', 'tls']},
        }
      ],
      'outbounds': [outbound, _direct(), _block()],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          {'type': 'field', 'outboundTag': 'direct', 'ip': ['geoip:private']},
        ],
      },
    };
    return jsonEncode(config);
  }

  Map<String, dynamic> _outbound(ParsedProxy proxy) => switch (proxy) {
        VmessConfig c => _vmess(c),
        VlessConfig c => _vless(c),
        TrojanConfig c => _trojan(c),
        ShadowsocksConfig c => _shadowsocks(c),
        _ => throw UnsupportedError(
            '${proxy.protocolLabel} не поддерживается на Android. Используйте серверы VLESS Reality, xHTTP, VMess, Trojan или Shadowsocks.'),
      };

  Map<String, dynamic> _vmess(VmessConfig c) => {
        'tag': 'proxy',
        'protocol': 'vmess',
        'settings': {
          'vnext': [
            {
              'address': c.host,
              'port': c.port,
              'users': [
                {
                  'id': c.uuid,
                  'alterId': c.alterId,
                  'security': c.security.isEmpty ? 'auto' : c.security,
                }
              ]
            }
          ]
        },
        'streamSettings': _stream(
          network: c.network,
          security: c.tls,
          sni: c.sni,
          host: c.wsHost,
          path: c.path,
          fingerprint: c.fingerprint,
        ),
        'mux': {'enabled': false},
      };

  Map<String, dynamic> _vless(VlessConfig c) => {
        'tag': 'proxy',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': c.host,
              'port': c.port,
              'users': [
                {
                  'id': c.uuid,
                  'encryption': 'none',
                  if (c.flow.isNotEmpty) 'flow': c.flow,
                }
              ]
            }
          ]
        },
        'streamSettings': _stream(
          network: c.transport,
          security: c.security,
          sni: c.sni,
          host: c.transportHost,
          path: c.path,
          fingerprint: c.fingerprint,
          publicKey: c.publicKey,
          shortId: c.shortId,
        ),
        'mux': {'enabled': false},
      };

  Map<String, dynamic> _trojan(TrojanConfig c) => {
        'tag': 'proxy',
        'protocol': 'trojan',
        'settings': {
          'servers': [
            {
              'address': c.host,
              'port': c.port,
              'password': c.password,
            }
          ]
        },
        'streamSettings': _stream(
          network: c.transport,
          security: c.security.isEmpty ? 'tls' : c.security,
          sni: c.sni,
          host: c.transportHost,
          path: c.path,
          fingerprint: c.fingerprint,
        ),
        'mux': {'enabled': false},
      };

  Map<String, dynamic> _shadowsocks(ShadowsocksConfig c) => {
        'tag': 'proxy',
        'protocol': 'shadowsocks',
        'settings': {
          'servers': [
            {
              'address': c.host,
              'port': c.port,
              'method': c.method,
              'password': c.password,
            }
          ]
        },
        'streamSettings': {'network': 'tcp'},
        'mux': {'enabled': false},
      };

  Map<String, dynamic> _stream({
    required String network,
    required String security,
    required String sni,
    required String host,
    String path = '',
    String fingerprint = '',
    String? publicKey,
    String? shortId,
  }) {
    final net = network.isEmpty ? 'tcp' : network;
    final Map<String, dynamic> stream = {'network': net};

    if (net == 'ws') {
      stream['wsSettings'] = {
        'path': path.isEmpty ? '/' : path,
        'headers': {'Host': sni.isNotEmpty ? sni : host},
      };
    } else if (net == 'grpc') {
      stream['grpcSettings'] = {'serviceName': path};
    } else if (net == 'h2' || net == 'http') {
      stream['network'] = 'h2';
      stream['httpSettings'] = {
        'host': [sni.isNotEmpty ? sni : host],
        'path': path.isEmpty ? '/' : path,
      };
    }

    if (security == 'tls' || security == 'reality') {
      final tlsKey = security == 'reality' ? 'realitySettings' : 'tlsSettings';
      stream['security'] = security;
      stream[tlsKey] = {
        'serverName': sni.isEmpty ? host : sni,
        'allowInsecure': false,
        if (fingerprint.isNotEmpty) 'fingerprint': fingerprint,
        if (publicKey != null && publicKey.isNotEmpty) 'publicKey': publicKey,
        if (shortId != null && shortId.isNotEmpty) 'shortId': shortId,
      };
    }

    return stream;
  }

  Map<String, dynamic> _direct() => {
        'tag': 'direct',
        'protocol': 'freedom',
        'settings': {'domainStrategy': 'UseIp'},
      };

  Map<String, dynamic> _block() => {
        'tag': 'blackhole',
        'protocol': 'blackhole',
      };
}
