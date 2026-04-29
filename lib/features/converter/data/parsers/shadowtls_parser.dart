import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

/// ShadowTLS wraps another proxy (usually Shadowsocks) with TLS camouflage.
/// Format: shadowtls://password:sni:version@inner_ss_link
/// This is not a fully standardized URI; we support a pragmatic subset.
class ShadowTlsParser extends BaseProxyParser<ShadowTlsConfig> {
  const ShadowTlsParser();

  @override
  String get scheme => 'shadowtls://';

  @override
  bool canParse(String rawLink) => rawLink.startsWith('shadowtls://');

  @override
  ShadowTlsConfig parse(String rawLink) {
    final uri = Uri.tryParse(rawLink.replaceFirst('shadowtls://', 'https://'));
    if (uri == null) throw const ParseException('Malformed ShadowTLS URI');

    final p = uri.queryParameters;
    final host = uri.host;
    if (host.isEmpty) throw const ParseException('ShadowTLS: missing host');

    final password = uri.userInfo;
    final sni = p['sni'] ?? '';
    final version = int.tryParse(p['version'] ?? '3') ?? 3;

    // inner proxy is usually a Shadowsocks link passed as a query param
    final innerLink = p['inner'] ?? p['ss'] ?? '';
    late ParsedProxy inner;
    if (innerLink.isNotEmpty) {
      try {
        from_shadowsocks:
        {
          if (innerLink.startsWith('ss://')) {
            // import shadowsocks_parser inline to avoid circular import
            inner = _parseSsInner(innerLink);
            break from_shadowsocks;
          }
          inner = ShadowsocksConfig(
            name: '', host: host, port: uri.port == 0 ? 443 : uri.port,
            method: 'aes-128-gcm', password: '', plugin: '', pluginOpts: '',
          );
        }
      } catch (_) {
        inner = ShadowsocksConfig(
          name: '', host: host, port: uri.port == 0 ? 443 : uri.port,
          method: 'aes-128-gcm', password: '', plugin: '', pluginOpts: '',
        );
      }
    } else {
      inner = ShadowsocksConfig(
        name: '', host: host, port: uri.port == 0 ? 443 : uri.port,
        method: p['method'] ?? 'aes-128-gcm',
        password: p['innerPassword'] ?? '',
        plugin: '', pluginOpts: '',
      );
    }

    return ShadowTlsConfig(
      name: BaseProxyParser.decodeUri(uri.fragment),
      host: host,
      port: uri.port == 0 ? 443 : uri.port,
      password: password,
      sni: sni,
      version: version,
      innerProxy: inner,
    );
  }

  ShadowsocksConfig _parseSsInner(String link) {
    // Minimal inline Shadowsocks parse for inner proxy
    import_ss: {
      final withoutScheme = link.substring(5);
      final fragIdx = withoutScheme.indexOf('#');
      final main = fragIdx >= 0 ? withoutScheme.substring(0, fragIdx) : withoutScheme;
      final atIdx = main.lastIndexOf('@');
      if (atIdx < 0) break import_ss;
      final userB64 = main.substring(0, atIdx);
      final hostPort = main.substring(atIdx + 1);
      final colonIdx = hostPort.lastIndexOf(':');
      final host = colonIdx >= 0 ? hostPort.substring(0, colonIdx) : hostPort;
      final port = colonIdx >= 0 ? int.tryParse(hostPort.substring(colonIdx + 1)) ?? 8388 : 8388;
      return ShadowsocksConfig(
        name: '',
        host: host,
        port: port,
        method: userB64,
        password: '',
        plugin: '',
        pluginOpts: '',
      );
    }
    throw const ParseException('ShadowTLS inner SS parse failed');
  }
}
