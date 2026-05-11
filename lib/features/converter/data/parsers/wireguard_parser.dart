import 'dart:convert';

import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

/// Parses wg-quick compatible config blocks embedded as a URI-like string
/// or as a raw INI-style text block.
///
/// Supported formats:
/// 1. INI block: [Interface] / [Peer] wg-quick format
/// 2. Standard URI: wireguard://host:port?privateKey=...&publicKey=...
/// 3. Internal config JSON: wireguard://host:port?config={JSON}#name
///    (produced by servers_notifier._rawLink for WireGuard configs)
class WireGuardParser extends BaseProxyParser<WireGuardConfig> {
  const WireGuardParser();

  @override
  String get scheme => 'wireguard://';

  @override
  bool canParse(String rawLink) =>
      rawLink.startsWith('wireguard://') ||
      rawLink.startsWith('[Interface]');

  @override
  WireGuardConfig parse(String rawLink) {
    if (rawLink.startsWith('[Interface]')) {
      return _parseWgQuick(rawLink);
    }
    return _parseWgUri(rawLink);
  }

  WireGuardConfig _parseWgUri(String rawLink) {
    final uri = Uri.tryParse(rawLink.replaceFirst('wireguard://', 'https://'));
    if (uri == null) throw const ParseException('Malformed WireGuard URI');

    final p = uri.queryParameters;
    final host = uri.host;
    final name = BaseProxyParser.decodeUri(uri.fragment);
    final port = uri.port == 0 ? 51820 : uri.port;

    // Internal _rawLink format: wireguard://host:port?config={JSON}#name
    final configParam = p['config'];
    if (configParam != null) {
      try {
        final config = json.decode(configParam) as Map<String, dynamic>;
        return WireGuardConfig(
          name: name,
          host: host,
          port: port,
          privateKey: config['privateKey'] as String? ?? '',
          publicKey: config['publicKey'] as String? ?? '',
          presharedKey: config['presharedKey'] as String? ?? '',
          addresses: ((config['addresses'] as List<dynamic>?) ?? [])
              .map((e) => e.toString())
              .toList(),
          dns: ((config['dns'] as List<dynamic>?) ?? [])
              .map((e) => e.toString())
              .toList(),
          mtu: config['mtu'] as int? ?? 1420,
          reserved: _parseReservedFromJson(config['reserved']),
        );
      } catch (_) {
        // Fall through to standard URI parsing
      }
    }

    // Standard URI format
    final privateKey = p['privateKey'] ?? p['private_key'] ?? '';
    final publicKey = p['publicKey'] ?? p['public_key'] ?? uri.userInfo;
    final addresses = (p['address'] ?? '').split(',').where((s) => s.isNotEmpty).toList();
    final dns = (p['dns'] ?? '').split(',').where((s) => s.isNotEmpty).toList();

    return WireGuardConfig(
      name: name,
      host: host,
      port: port,
      privateKey: privateKey,
      publicKey: publicKey,
      presharedKey: p['presharedKey'] ?? p['preshared_key'] ?? '',
      addresses: addresses,
      dns: dns,
      mtu: int.tryParse(p['mtu'] ?? '') ?? 1420,
      reserved: _parseReserved(p['reserved']),
    );
  }

  WireGuardConfig _parseWgQuick(String raw) {
    final lines = raw.split('\n').map((l) => l.trim()).toList();
    final iface = <String, String>{};
    final peer = <String, String>{};
    var section = '';
    for (final line in lines) {
      if (line.startsWith('[Interface]')) { section = 'iface'; continue; }
      if (line.startsWith('[Peer]')) { section = 'peer'; continue; }
      if (line.isEmpty || line.startsWith('#')) continue;
      final eqIdx = line.indexOf('=');
      if (eqIdx < 0) continue;
      final k = line.substring(0, eqIdx).trim().toLowerCase();
      final v = line.substring(eqIdx + 1).trim();
      if (section == 'iface') iface[k] = v;
      else if (section == 'peer') peer[k] = v;
    }

    final endpoint = peer['endpoint'] ?? '';
    final colonIdx = endpoint.lastIndexOf(':');
    final host = colonIdx >= 0 ? endpoint.substring(0, colonIdx) : endpoint;
    final port = colonIdx >= 0 ? int.tryParse(endpoint.substring(colonIdx + 1)) ?? 51820 : 51820;

    return WireGuardConfig(
      name: '',
      host: host,
      port: port,
      privateKey: iface['privatekey'] ?? '',
      publicKey: peer['publickey'] ?? '',
      presharedKey: peer['presharedkey'] ?? '',
      addresses: (iface['address'] ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      dns: (iface['dns'] ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      mtu: int.tryParse(iface['mtu'] ?? '') ?? 1420,
    );
  }

  // Parses reserved from a JSON value that may be List<dynamic> or null
  static List<int>? _parseReservedFromJson(dynamic value) {
    if (value == null) return null;
    if (value is List) {
      final result = value
          .map((e) => e is int ? e : int.tryParse(e.toString()) ?? 0)
          .toList();
      return result.length == 3 ? result : null;
    }
    return null;
  }

  // Parses reserved from a comma-separated string query parameter
  static List<int>? _parseReserved(String? s) {
    if (s == null || s.isEmpty) return null;
    final parts = s.split(',');
    final result = parts.map((p) => int.tryParse(p.trim()) ?? 0).toList();
    return result.length == 3 ? result : null;
  }
}
