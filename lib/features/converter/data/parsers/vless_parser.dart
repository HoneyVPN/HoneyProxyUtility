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

    final uuid = Uri.decodeComponent(uri.userInfo);
    if (uuid.isEmpty) throw const ParseException('VLESS: missing UUID');

    final p = uri.queryParameters;
    final transport = switch (p['type'] ?? 'tcp') {
      'raw' => 'tcp',
      'websocket' => 'ws',
      final value => value,
    };
    if (p['headerType'] != null &&
        p['headerType']!.isNotEmpty &&
        p['headerType'] != 'none') {
      throw const UnsupportedConfigurationException(
        'VLESS headerType is unsupported by this app.',
      );
    }
    if (transport == 'xhttp' && (p['extra'] ?? '').isNotEmpty) {
      throw const UnsupportedConfigurationException(
        'VLESS xHTTP extra is unsupported by this app.',
      );
    }
    if (p['security'] == 'reality' &&
        (p['spx'] ?? '').isNotEmpty &&
        p['spx'] != '/') {
      throw const UnsupportedConfigurationException(
        'VLESS Reality spiderX is unsupported by this core.',
      );
    }
    for (final key in const ['ech', 'pqv', 'ed', 'eh']) {
      if ((p[key] ?? '').isNotEmpty && p[key] != '0') {
        throw UnsupportedConfigurationException(
          'VLESS $key is unsupported by this app.',
        );
      }
    }
    final insecureValue = p['allowInsecure'] ?? p['insecure'] ?? '0';
    if (!const {'0', '1', 'false', 'true'}.contains(insecureValue)) {
      throw const UnsupportedConfigurationException(
        'VLESS insecure must be a boolean.',
      );
    }
    final config = VlessConfig(
      name: BaseProxyParser.decodeUri(uri.fragment),
      host: host.startsWith('[') ? host.substring(1, host.length - 1) : host,
      port: uri.port == 0 ? 443 : uri.port,
      uuid: uuid,
      flow: p['flow'] ?? '',
      encryption: p['encryption'] ?? 'none',
      security: p['security'] ?? 'none',
      sni: p['sni'] ?? '',
      fingerprint: p['fp'] ?? '',
      publicKey: p['pbk'] ?? '',
      shortId: p['sid'] ?? '',
      spiderX: p['spx'] ?? '',
      transport: transport,
      // queryParameters already percent-decodes exactly once. A second decode
      // changes literal percent escapes in paths such as /%2F into //.
      path: p['path'] ?? '/',
      transportHost: p['host'] ?? '',
      grpcServiceName: p['serviceName'] ?? '',
      xhttpMode: p['mode'] ?? '',
      xPaddingBytes:
          p['xPaddingBytes'] ?? p['x_padding_bytes'] ?? p['paddingBytes'] ?? '',
      alpn: (p['alpn'] ?? '').split(',').where((v) => v.isNotEmpty).toList(),
      allowInsecure: insecureValue == '1' || insecureValue == 'true',
    );
    try {
      config.validateCoreCompatibility();
    } on UnsupportedError catch (error) {
      throw UnsupportedConfigurationException(error.message.toString());
    }
    return config;
  }
}
