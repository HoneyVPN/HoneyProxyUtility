import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

class Hysteria2Parser extends BaseProxyParser<Hysteria2Config> {
  const Hysteria2Parser();

  @override
  String get scheme => 'hy2://';

  @override
  bool canParse(String rawLink) =>
      rawLink.startsWith('hy2://') || rawLink.startsWith('hysteria2://');

  @override
  Hysteria2Config parse(String rawLink) {
    // Hysteria2 supports port hopping: hy2://auth@host:443,5000-6000?...
    // Strip port hopping range before URI parsing so Uri.parse doesn't fail
    var cleaned = rawLink
        .replaceFirst('hysteria2://', 'https://')
        .replaceFirst('hy2://', 'https://');

    // Extract port hopping if present: host:port,range or host:port-range
    String? portHopping;
    final portHopRegex = RegExp(r'(https://.+@[^:]+):([0-9]+[,\-][0-9\-,]+)([/?#]|$)');
    final hopMatch = portHopRegex.firstMatch(cleaned);
    if (hopMatch != null) {
      portHopping = hopMatch.group(2);
      // Keep only first port for URI parsing
      final firstPort = portHopping!.split(RegExp(r'[,\-]')).first;
      cleaned = cleaned.replaceFirst(':${hopMatch.group(2)!}', ':$firstPort');
    }

    final uri = Uri.tryParse(cleaned);
    if (uri == null) throw const ParseException('Malformed Hysteria2 URI');

    final host = uri.host;
    if (host.isEmpty) throw const ParseException('Hysteria2: missing host');

    final p = uri.queryParameters;
    return Hysteria2Config(
      name: BaseProxyParser.decodeUri(uri.fragment),
      host: host,
      port: uri.port == 0 ? 443 : uri.port,
      auth: uri.userInfo.isEmpty ? '' : Uri.decodeComponent(uri.userInfo),
      sni: p['sni'] ?? '',
      insecure: (p['insecure'] ?? p['allowinsecure'] ?? '0') == '1',
      obfs: p['obfs'] ?? '',
      obfsPassword: p['obfs-password'] ?? '',
      pinSha256: p['pinSHA256'] ?? '',
      ports: portHopping ?? p['mport'],
    );
  }
}
