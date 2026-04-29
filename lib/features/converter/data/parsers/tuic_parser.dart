import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

class TuicParser extends BaseProxyParser<TuicConfig> {
  const TuicParser();

  @override
  String get scheme => 'tuic://';

  @override
  bool canParse(String rawLink) => rawLink.startsWith('tuic://');

  @override
  TuicConfig parse(String rawLink) {
    // tuic://uuid:password@host:port?params#name
    final uri = Uri.tryParse(rawLink.replaceFirst('tuic://', 'https://'));
    if (uri == null) throw const ParseException('Malformed TUIC URI');

    final host = uri.host;
    if (host.isEmpty) throw const ParseException('TUIC: missing host');

    final userInfo = uri.userInfo;
    final colonIdx = userInfo.indexOf(':');
    final uuid = colonIdx >= 0 ? userInfo.substring(0, colonIdx) : userInfo;
    final password = colonIdx >= 0 ? userInfo.substring(colonIdx + 1) : '';

    final p = uri.queryParameters;
    return TuicConfig(
      name: BaseProxyParser.decodeUri(uri.fragment),
      host: host,
      port: uri.port == 0 ? 443 : uri.port,
      uuid: uuid,
      password: password,
      sni: p['sni'] ?? '',
      alpn: p['alpn'] ?? '',
      congestionControl: p['congestion_control'] ?? p['cc'] ?? 'bbr',
      udpRelayMode: p['udp_relay_mode'] ?? p['udpRelayMode'] ?? 'native',
      allowInsecure: (p['allow_insecure'] ?? p['allowInsecure'] ?? '0') == '1',
    );
  }
}
