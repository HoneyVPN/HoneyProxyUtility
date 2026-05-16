import 'dart:convert';

import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

/// ShadowTLS wraps another proxy (usually Shadowsocks) with TLS camouflage.
///
/// Supported formats:
/// 1. Standard URI: shadowtls://password@host:port?sni=...&version=3&inner=ss://...
/// 2. Internal config JSON: shadowtls://host:port?config={JSON}#name
///    (produced by servers_notifier._rawLink for ShadowTLS configs)
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
    final port = uri.port == 0 ? 443 : uri.port;
    final name = BaseProxyParser.decodeUri(uri.fragment);

    // Internal _rawLink format: shadowtls://host:port?config={JSON}#name
    final configParam = p['config'];
    if (configParam != null) {
      try {
        final config = json.decode(configParam) as Map<String, dynamic>;
        final password = config['password'] as String? ?? '';
        final sni = config['sni'] as String? ?? '';
        final version = config['version'] as int? ?? 3;
        final innerLink = config['inner'] as String? ?? '';

        late ParsedProxy inner;
        if (innerLink.isNotEmpty) {
          try {
            if (innerLink.startsWith('ss://')) {
              inner = _parseSsInner(innerLink);
            } else {
              // Delegate to the full link dispatcher would cause circular import;
              // for non-SS inner proxies fall back to a placeholder SS config
              inner = _fallbackSs(host, port);
            }
          } catch (_) {
            inner = _fallbackSs(host, port);
          }
        } else {
          inner = _fallbackSs(host, port);
        }

        return ShadowTlsConfig(
          name: name,
          host: host,
          port: port,
          password: password,
          sni: sni,
          version: version,
          innerProxy: inner,
        );
      } catch (e) {
        if (e is ParseException) rethrow;
        // Fall through to standard URI parsing
      }
    }

    // Standard URI format
    final password = uri.userInfo;
    final sni = p['sni'] ?? '';
    final version = int.tryParse(p['version'] ?? '3') ?? 3;

    final innerLink = p['inner'] ?? p['ss'] ?? '';
    late ParsedProxy inner;
    if (innerLink.isNotEmpty) {
      try {
        if (innerLink.startsWith('ss://')) {
          inner = _parseSsInner(innerLink);
        } else {
          inner = _fallbackSs(host, port);
        }
      } catch (_) {
        inner = _fallbackSs(host, port);
      }
    } else {
      inner = ShadowsocksConfig(
        name: '', host: host, port: port,
        method: p['method'] ?? 'aes-128-gcm',
        password: p['innerPassword'] ?? '',
        plugin: '', pluginOpts: '',
      );
    }

    return ShadowTlsConfig(
      name: name,
      host: host,
      port: port,
      password: password,
      sni: sni,
      version: version,
      innerProxy: inner,
    );
  }

  // Parses a Shadowsocks ss:// link for use as the inner proxy.
  // Handles SIP002 format: ss://BASE64(method:password)@host:port#name
  ShadowsocksConfig _parseSsInner(String link) {
    final withoutScheme = link.substring(5);
    final fragIdx = withoutScheme.indexOf('#');
    final main = fragIdx >= 0 ? withoutScheme.substring(0, fragIdx) : withoutScheme;
    final atIdx = main.lastIndexOf('@');
    if (atIdx < 0) throw const ParseException('ShadowTLS inner SS: missing @');

    final userPart = main.substring(0, atIdx);
    final hostPort = main.substring(atIdx + 1);
    final colonIdx = hostPort.lastIndexOf(':');
    final host = colonIdx >= 0 ? hostPort.substring(0, colonIdx) : hostPort;
    final port = colonIdx >= 0 ? int.tryParse(hostPort.substring(colonIdx + 1)) ?? 8388 : 8388;

    // SIP002: userPart is base64(method:password)
    String method = 'aes-128-gcm';
    String password = '';
    try {
      final decoded = utf8.decode(base64.decode(_addPadding(userPart)));
      final sep = decoded.indexOf(':');
      if (sep >= 0) {
        method = decoded.substring(0, sep);
        password = decoded.substring(sep + 1);
      } else {
        method = decoded;
      }
    } catch (_) {
      // userPart is not base64 — treat as raw method (legacy format)
      method = userPart;
    }

    return ShadowsocksConfig(
      name: '',
      host: host,
      port: port,
      method: method,
      password: password,
      plugin: '',
      pluginOpts: '',
    );
  }

  ShadowsocksConfig _fallbackSs(String host, int port) => ShadowsocksConfig(
    name: '', host: host, port: port,
    method: 'aes-128-gcm', password: '', plugin: '', pluginOpts: '',
  );

  static String _addPadding(String s) {
    final mod = s.length % 4;
    if (mod == 0) return s;
    return s + '=' * (4 - mod);
  }
}
