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
    // Rewrite only the multi-port suffix: encoded auth and IPv6 stay intact.
    var cleaned = rawLink.replaceFirst(
      RegExp(r'^(hysteria2|hy2)://'),
      'https://',
    );

    final authorityStart = cleaned.indexOf('://') + 3;
    final suffix = cleaned.substring(authorityStart);
    final end = suffix.indexOf(RegExp(r'[/?#]'));
    final authorityEnd = end < 0 ? cleaned.length : authorityStart + end;
    final authority = cleaned.substring(authorityStart, authorityEnd);
    final hostStart = authority.lastIndexOf('@') + 1;
    final hostPort = authority.substring(hostStart);
    final separator = hostPort.startsWith('[')
        ? (hostPort.indexOf(']') >= 0 ? hostPort.indexOf(']') + 1 : -1)
        : hostPort.lastIndexOf(':');
    String? portHopping;
    if (separator >= 0 &&
        separator < hostPort.length &&
        hostPort[separator] == ':') {
      final portText = hostPort.substring(separator + 1);
      if (portText.contains(',') || portText.contains('-')) {
        portHopping = portText;
        final firstPort = portText.split(RegExp(r'[,-]')).first;
        final portStart = authorityStart + hostStart + separator + 1;
        cleaned = cleaned.replaceRange(portStart, authorityEnd, firstPort);
      }
    }

    final uri = Uri.tryParse(cleaned);
    if (uri == null) throw const ParseException('Malformed Hysteria2 URI');

    final host = uri.host;
    if (host.isEmpty) throw const ParseException('Hysteria2: missing host');

    final p = uri.queryParameters;
    for (final key in const [
      'ech',
      'realm',
      'minHopInterval',
      'maxHopInterval',
      'hop_interval_max',
    ]) {
      if ((p[key] ?? '').isNotEmpty) {
        throw UnsupportedConfigurationException(
          'Hysteria2 $key is unsupported by this core.',
        );
      }
    }
    final queryPorts = p['mport'] ?? p['ports'];
    if (p['mport'] != null && p['ports'] != null && p['mport'] != p['ports']) {
      throw const UnsupportedConfigurationException(
        'Hysteria2 ports and mport conflict.',
      );
    }
    if (portHopping != null &&
        (queryPorts ?? '').isNotEmpty &&
        portHopping != queryPorts) {
      throw const UnsupportedConfigurationException(
        'Hysteria2 inline ports and mport conflict.',
      );
    }
    final insecure = p['insecure'] ?? p['allowinsecure'] ?? '0';
    if (!const {'0', '1', 'false', 'true'}.contains(insecure)) {
      throw const UnsupportedConfigurationException(
        'Hysteria2 insecure must be a boolean.',
      );
    }
    final config = Hysteria2Config(
      name: BaseProxyParser.decodeUri(uri.fragment),
      host: host.startsWith('[') ? host.substring(1, host.length - 1) : host,
      port: uri.port == 0 ? 443 : uri.port,
      auth: uri.userInfo.isEmpty ? '' : Uri.decodeComponent(uri.userInfo),
      sni: p['sni'] ?? '',
      insecure: insecure == '1' || insecure == 'true',
      obfs: p['obfs'] ?? '',
      obfsPassword: p['obfs-password'] ?? '',
      pinSha256: p['pinSHA256'] ?? p['pinSha256'] ?? '',
      ports: portHopping ?? queryPorts,
      hopInterval: p['hopInterval'] ?? p['hop_interval'] ?? '',
    );
    try {
      config.validateCoreCompatibility();
    } on UnsupportedError catch (error) {
      throw UnsupportedConfigurationException(error.message.toString());
    }
    return config;
  }
}
