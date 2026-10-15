import 'dart:convert';
import '../../converter/data/parsers/link_dispatcher.dart';
import '../../converter/domain/entities/parsed_proxy.dart';
import '../../servers/data/models/server_profile_model.dart';

Map<String, String> diagnosticConnectionDetails(ServerProfileModel? profile) {
  const unknown = {
    'transport': 'unknown',
    'security': 'unknown',
    'flow': 'unknown',
  };
  if (profile == null || profile.configJson.length > 65536) return unknown;
  try {
    final stored = jsonDecode(profile.configJson);
    if (stored is! Map ||
        stored['rawLink'] is! String ||
        (stored['rawLink'] as String).length > 65536)
      return unknown;
    final proxy = const LinkDispatcher().dispatch(stored['rawLink'] as String);
    String transport(String value) => switch (value) {
      'tcp' => 'tcp',
      'ws' || 'websocket' => 'ws',
      'h2' || 'http' => 'http',
      'grpc' => 'grpc',
      'httpupgrade' => 'httpupgrade',
      'xhttp' => 'xhttp',
      'quic' => 'quic',
      'udp' => 'udp',
      _ => 'unknown',
    };
    String security(String value) => switch (value) {
      'tls' => 'tls',
      'reality' => 'reality',
      'xtls' => 'xtls',
      '' || 'none' => 'none',
      _ => 'unknown',
    };
    return switch (proxy) {
      VlessConfig c => {
        'transport': transport(c.transport),
        'security': security(c.security),
        'flow': c.flow == 'xtls-rprx-vision'
            ? 'xtls-rprx-vision'
            : c.flow.isEmpty
            ? 'none'
            : 'unknown',
      },
      VmessConfig c => {
        'transport': transport(c.network),
        'security': c.tls == 'tls' ? 'tls' : 'none',
        'flow': 'none',
      },
      TrojanConfig c => {
        'transport': transport(c.transport),
        'security': security(c.security),
        'flow': 'none',
      },
      Hysteria2Config _ ||
      TuicConfig _ => {'transport': 'quic', 'security': 'tls', 'flow': 'none'},
      WireGuardConfig _ || AmneziaWGConfig _ => {
        'transport': 'udp',
        'security': 'none',
        'flow': 'none',
      },
      ShadowTlsConfig _ => {
        'transport': 'tcp',
        'security': 'tls',
        'flow': 'none',
      },
      NaiveConfig c => {
        'transport': c.scheme == 'https'
            ? 'https'
            : c.scheme == 'quic'
            ? 'quic'
            : 'unknown',
        'security': c.scheme == 'https' ? 'tls' : 'unknown',
        'flow': 'none',
      },
      ShadowsocksConfig _ => unknown,
    };
  } catch (_) {
    return unknown;
  }
}
