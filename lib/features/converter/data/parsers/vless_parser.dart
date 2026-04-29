import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

class VlessParser extends BaseProxyParser<VlessConfig> {
  const VlessParser();

  @override
  String get scheme => 'vless://';

  @override
  bool canParse(String rawLink) => rawLink.startsWith('vless://');

  @override
  VlessConfig parse(String rawLink) {
    // vless://uuid@host:port?params#name
    final uri = Uri.tryParse(rawLink.replaceFirst('vless://', 'https://'));
    if (uri == null) throw const ParseException('Malformed VLESS URI');

    final host = uri.host;
    if (host.isEmpty) throw const ParseException('VLESS: missing host');

    final p = uri.queryParameters;
    return VlessConfig(
      name: BaseProxyParser.decodeUri(uri.fragment),
      host: host,
      port: uri.port == 0 ? 443 : uri.port,
      uuid: uri.userInfo,
      flow: p['flow'] ?? '',
      encryption: p['encryption'] ?? 'none',
      security: p['security'] ?? 'none',
      sni: p['sni'] ?? '',
      fingerprint: p['fp'] ?? '',
      publicKey: p['pbk'] ?? '',
      shortId: p['sid'] ?? '',
      spiderX: p['spx'] ?? '',
      transport: p['type'] ?? 'tcp',
      path: BaseProxyParser.decodeUri(p['path'] ?? '/'),
      transportHost: p['host'] ?? '',
      grpcServiceName: p['serviceName'] ?? '',
    );
  }
}
