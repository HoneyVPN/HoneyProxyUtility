import 'dart:convert';

import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

/// Parses AmneziaWG configs in wg-quick format with extra obfuscation fields.
///
/// Recognized formats:
/// 1. Extended wg-quick INI with Jc/Jmin/Jmax/S1/S2/H1/H2/H3/H4 fields
/// 2. awg:// URI (Amnezia app share format) — same params as query args
class AmneziaWGParser extends BaseProxyParser<AmneziaWGConfig> {
  const AmneziaWGParser();

  @override
  String get scheme => 'awg://';

  static final _awgFields = RegExp(
    r'^\s*(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)\s*=',
    multiLine: true,
    caseSensitive: false,
  );

  @override
  bool canParse(String rawLink) =>
      rawLink.startsWith('awg://') ||
      (rawLink.startsWith('[Interface]') && _awgFields.hasMatch(rawLink));

  @override
  AmneziaWGConfig parse(String rawLink) {
    if (rawLink.startsWith('awg://')) return _parseUri(rawLink);
    return _parseIni(rawLink);
  }

  AmneziaWGConfig _parseUri(String rawLink) {
    final uri = Uri.tryParse(rawLink.replaceFirst('awg://', 'https://'));
    if (uri == null) throw const ParseException('Malformed awg:// URI');
    final p = uri.queryParameters;
    final host = uri.host;
    if (host.isEmpty) throw const ParseException('AmneziaWG: missing host');
    final name = BaseProxyParser.decodeUri(uri.fragment);
    final port = uri.port == 0 ? 51820 : uri.port;

    // Internal _rawLink format: awg://host:port?config={JSON}#name
    final configParam = p['config'];
    if (configParam != null) {
      try {
        final c = json.decode(configParam) as Map<String, dynamic>;
        return AmneziaWGConfig(
          name: name,
          host: host,
          port: port,
          privateKey: c['privateKey'] as String? ?? '',
          publicKey: c['publicKey'] as String? ?? '',
          presharedKey: c['presharedKey'] as String? ?? '',
          addresses: ((c['addresses'] as List<dynamic>?) ?? []).map((e) => e.toString()).toList(),
          dns: ((c['dns'] as List<dynamic>?) ?? []).map((e) => e.toString()).toList(),
          mtu: c['mtu'] as int? ?? 1420,
          reserved: _parseReservedFromJson(c['reserved']),
          jc: c['jc'] as int? ?? 4,
          jmin: c['jmin'] as int? ?? 40,
          jmax: c['jmax'] as int? ?? 70,
          s1: c['s1'] as int? ?? 0,
          s2: c['s2'] as int? ?? 0,
          s3: c['s3'] as int? ?? 0,
          s4: c['s4'] as int? ?? 0,
          h1: c['h1'] as int? ?? 1,
          h2: c['h2'] as int? ?? 2,
          h3: c['h3'] as int? ?? 3,
          h4: c['h4'] as int? ?? 4,
        );
      } catch (_) {
        // Fall through to standard URI parsing
      }
    }

    final addresses = (p['address'] ?? '').split(',').where((s) => s.isNotEmpty).toList();
    final dns = (p['dns'] ?? '').split(',').where((s) => s.isNotEmpty).toList();
    return AmneziaWGConfig(
      name: name,
      host: host,
      port: port,
      privateKey: p['privateKey'] ?? p['private_key'] ?? '',
      publicKey: p['publicKey'] ?? p['public_key'] ?? uri.userInfo,
      presharedKey: p['presharedKey'] ?? p['preshared_key'] ?? '',
      addresses: addresses,
      dns: dns,
      mtu: int.tryParse(p['mtu'] ?? '') ?? 1420,
      jc: int.tryParse(p['jc'] ?? p['Jc'] ?? '') ?? 4,
      jmin: int.tryParse(p['jmin'] ?? p['Jmin'] ?? '') ?? 40,
      jmax: int.tryParse(p['jmax'] ?? p['Jmax'] ?? '') ?? 70,
      s1: int.tryParse(p['s1'] ?? p['S1'] ?? '') ?? 0,
      s2: int.tryParse(p['s2'] ?? p['S2'] ?? '') ?? 0,
      s3: int.tryParse(p['s3'] ?? p['S3'] ?? '') ?? 0,
      s4: int.tryParse(p['s4'] ?? p['S4'] ?? '') ?? 0,
      h1: int.tryParse(p['h1'] ?? p['H1'] ?? '') ?? 1,
      h2: int.tryParse(p['h2'] ?? p['H2'] ?? '') ?? 2,
      h3: int.tryParse(p['h3'] ?? p['H3'] ?? '') ?? 3,
      h4: int.tryParse(p['h4'] ?? p['H4'] ?? '') ?? 4,
    );
  }

  static List<int>? _parseReservedFromJson(dynamic value) {
    if (value == null) return null;
    if (value is List) {
      final result = value.map((e) => e is int ? e : int.tryParse(e.toString()) ?? 0).toList();
      return result.length == 3 ? result : null;
    }
    return null;
  }

  AmneziaWGConfig _parseIni(String raw) {
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

    return AmneziaWGConfig(
      name: '',
      host: host,
      port: port,
      privateKey: iface['privatekey'] ?? '',
      publicKey: peer['publickey'] ?? '',
      presharedKey: peer['presharedkey'] ?? '',
      addresses: (iface['address'] ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      dns: (iface['dns'] ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      mtu: int.tryParse(iface['mtu'] ?? '') ?? 1420,
      jc: int.tryParse(iface['jc'] ?? '') ?? 4,
      jmin: int.tryParse(iface['jmin'] ?? '') ?? 40,
      jmax: int.tryParse(iface['jmax'] ?? '') ?? 70,
      s1: int.tryParse(iface['s1'] ?? '') ?? 0,
      s2: int.tryParse(iface['s2'] ?? '') ?? 0,
      s3: int.tryParse(iface['s3'] ?? '') ?? 0,
      s4: int.tryParse(iface['s4'] ?? '') ?? 0,
      h1: int.tryParse(iface['h1'] ?? '') ?? 1,
      h2: int.tryParse(iface['h2'] ?? '') ?? 2,
      h3: int.tryParse(iface['h3'] ?? '') ?? 3,
      h4: int.tryParse(iface['h4'] ?? '') ?? 4,
    );
  }
}
