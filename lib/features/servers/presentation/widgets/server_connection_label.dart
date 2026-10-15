import 'dart:convert';

import '../../../converter/data/parsers/link_dispatcher.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../data/models/server_profile_model.dart';

/// Display-only connection details. Never expose addresses, credentials or
/// infer a transport from unrelated fields in an unknown configuration shape.
abstract final class ServerConnectionLabel {
  static String fromProfile(ServerProfileModel profile) {
    try {
      final stored = jsonDecode(profile.configJson);
      if (stored is Map<String, dynamic> && stored['rawLink'] is String) {
        return fromProxy(
          const LinkDispatcher().dispatch(stored['rawLink'] as String),
        );
      }
    } catch (_) {
      // Legacy/unsupported profiles still retain their known protocol label.
    }
    return _protocol(profile.protocol);
  }

  static String fromProxy(ParsedProxy proxy) {
    final details = switch (proxy) {
      VlessConfig c => [_transport(c.transport), _security(c.security)],
      VmessConfig c => [_transport(c.network), if (c.tls == 'tls') 'TLS'],
      TrojanConfig c => [_transport(c.transport), _security(c.security)],
      Hysteria2Config _ || TuicConfig _ => ['QUIC', 'TLS'],
      WireGuardConfig _ || AmneziaWGConfig _ => ['UDP'],
      NaiveConfig c => switch (c.scheme) {
        'https' => ['HTTPS'],
        'quic' => ['QUIC'],
        _ => <String>[],
      },
      // Describe this outer layer, rather than borrowing the inner transport.
      ShadowTlsConfig _ => ['TCP', 'TLS'],
      // A plugin's obfs=tls is camouflage, not evidence of actual TLS.
      ShadowsocksConfig _ => <String>[],
    };
    return [
      proxy.protocolLabel,
      ...details.where((detail) => detail.isNotEmpty),
    ].join(' · ');
  }

  static String _transport(String value) => switch (value) {
    'tcp' => 'TCP',
    'ws' || 'websocket' => 'WebSocket',
    'h2' || 'http' => 'HTTP/2',
    'grpc' => 'gRPC',
    'httpupgrade' => 'HTTPUpgrade',
    'xhttp' => 'XHTTP',
    'quic' => 'QUIC',
    'udp' => 'UDP',
    _ => '',
  };

  static String _security(String value) => switch (value) {
    'tls' => 'TLS',
    'reality' => 'REALITY',
    'xtls' => 'XTLS',
    _ => '',
  };

  static String _protocol(String value) => switch (value.toLowerCase()) {
    'vless' => 'VLESS',
    'vmess' => 'VMess',
    'trojan' => 'Trojan',
    'ss' || 'shadowsocks' => 'SS',
    'hy2' || 'hysteria2' => 'Hy2',
    'tuic' => 'TUIC',
    'wg' || 'wireguard' => 'WG',
    'awg' => 'AWG',
    'naive' => 'NaïveProxy',
    'shadowtls' => 'ShadowTLS',
    _ => '',
  };
}
