import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

class TrojanParser extends BaseProxyParser<TrojanConfig> {
  const TrojanParser();

  @override
  String get scheme => 'trojan://';

  @override
  bool canParse(String rawLink) => rawLink.startsWith('trojan://');

  @override
  TrojanConfig parse(String rawLink) {
    final uri = Uri.tryParse(rawLink.replaceFirst('trojan://', 'https://'));
    if (uri == null) throw const ParseException('Malformed Trojan URI');

    final host = uri.host;
    if (host.isEmpty) throw const ParseException('Trojan: missing host');

    final p = uri.queryParameters;
    final security = p['security'] ?? 'tls';
    return TrojanConfig(
      name: BaseProxyParser.decodeUri(uri.fragment),
      host: host,
      port: uri.port == 0 ? 443 : uri.port,
      password: Uri.decodeComponent(uri.userInfo),
      security: security,
      sni: p['sni'] ?? '',
      alpn: p['alpn'] ?? '',
      fingerprint: p['fp'] ?? '',
      transport: p['type'] ?? 'tcp',
      path: BaseProxyParser.decodeUri(p['path'] ?? '/'),
      transportHost: p['host'] ?? '',
    );
  }
}
