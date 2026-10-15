import 'dart:convert';

import 'base_parser.dart';
import 'wg_quick_support.dart';
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
    r'^\s*(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|J[1-3]|Itime|'
    r'header_?protection_?key|content_?padding_?addition|'
    r'rekey_?after_?time|rekey_?timeout|reject_?after_?time|'
    r'keepalive_?timeout|max_?handshake_?attempts|'
    r'random_?trailers|disable_?cookies)\s*=([^\r\n]*)',
    multiLine: true,
    caseSensitive: false,
  );

  // These fields affect protocol/security behavior and cannot be represented
  // by this app's current DTO. Never import them as a different, scalar-only
  // profile. Empty optional fields have no active behavior to discard.
  static const _unsupportedFields = <String, String>{
    'headerprotectionkey': 'header_protection_key',
    'contentpaddingaddition': 'content_padding_addition',
    'rekeyaftertime': 'rekey_after_time',
    'rekeytimeout': 'rekey_timeout',
    'rejectaftertime': 'reject_after_time',
    'keepalivetimeout': 'keepalive_timeout',
    'maxhandshakeattempts': 'max_handshake_attempts',
    'randomtrailers': 'RandomTrailers',
    'disablecookies': 'DisableCookies',
    'i1': 'I1',
    'i2': 'I2',
    'i3': 'I3',
    'i4': 'I4',
    'i5': 'I5',
    'j1': 'J1',
    'j2': 'J2',
    'j3': 'J3',
    'itime': 'Itime',
  };

  static void _checkSupportedParameters(Map<dynamic, dynamic> parameters) {
    for (final entry in parameters.entries) {
      final key = entry.key.toString().toLowerCase().replaceAll('_', '');
      final value = entry.value;
      if (key == 'amnezia' && value is Map) {
        _checkSupportedParameters(value);
      }
      if (value == null || value is String && value.trim().isEmpty) continue;
      if (_inactiveAdvancedFeature(key, value)) continue;
      final unsupported = _unsupportedFields[key];
      if (unsupported != null) {
        throw UnsupportedConfigurationException(
          'AmneziaWG: unsupported advanced parameter $unsupported '
          '(including AWG 3.1). This profile cannot be applied.',
        );
      }
      if (const {'h1', 'h2', 'h3', 'h4'}.contains(key) &&
          _headerScalar(value) == null) {
        throw UnsupportedConfigurationException(
          'AmneziaWG: ${key.toUpperCase()} ranges/advanced forms '
          'are unsupported. Only scalar integer headers or singleton ranges are supported.',
        );
      }
    }
  }

  static bool _inactiveAdvancedFeature(String key, Object? value) =>
      _unsupportedFields.containsKey(key) &&
      (const {
            'false',
            'off',
            '0',
            '0-0',
          }.contains(value.toString().trim().toLowerCase()) ||
          value is List && value.isEmpty);

  static int? _headerScalar(dynamic value) {
    final text = value?.toString().trim() ?? '';
    var integer = int.tryParse(text);
    if (integer == null) {
      final range = RegExp(r'^(\d+)-(\d+)$').firstMatch(text);
      if (range != null && range.group(1) == range.group(2)) {
        integer = int.tryParse(range.group(1)!);
      }
    }
    return integer != null && integer >= 0 && integer <= 4294967295
        ? integer
        : null;
  }

  static int _headerValue(dynamic value, int fallback) =>
      _headerScalar(value) ?? fallback;

  @override
  bool canParse(String rawLink) =>
      rawLink.startsWith('awg://') ||
      (isWgQuickConfig(rawLink) &&
          _awgFields.allMatches(rawLink).any((match) {
            final key = match.group(1)!.toLowerCase().replaceAll('_', '');
            final value = match.group(2)!.trim();
            if (_inactiveAdvancedFeature(key, value)) return false;
            if (!_unsupportedFields.containsKey(key)) return true;
            return value.isNotEmpty &&
                !(key == 'itime' && int.tryParse(value) == 0);
          }));

  @override
  AmneziaWGConfig parse(String rawLink) {
    if (rawLink.startsWith('awg://')) return _parseUri(rawLink);
    return _parseIni(rawLink);
  }

  AmneziaWGConfig _parseUri(String rawLink) {
    final uri = Uri.tryParse(rawLink);
    if (uri == null) throw const ParseException('Malformed awg:// URI');
    final p = uri.queryParameters;
    _checkSupportedParameters(p);
    final host = uri.host;
    if (host.isEmpty) throw const ParseException('AmneziaWG: missing host');
    final name = BaseProxyParser.decodeUri(uri.fragment);
    final port = uri.port == 0 ? 51820 : uri.port;

    // Internal _rawLink format: awg://host:port?config={JSON}#name
    final configParam = p['config'];
    if (configParam != null) {
      try {
        final c = json.decode(configParam) as Map<String, dynamic>;
        _checkSupportedParameters(c);
        return AmneziaWGConfig(
          name: name,
          host: host,
          port: port,
          privateKey: c['privateKey'] as String? ?? '',
          publicKey: c['publicKey'] as String? ?? '',
          presharedKey: c['presharedKey'] as String? ?? '',
          addresses: ((c['addresses'] as List<dynamic>?) ?? [])
              .map((e) => e.toString())
              .toList(),
          dns: ((c['dns'] as List<dynamic>?) ?? [])
              .map((e) => e.toString())
              .toList(),
          mtu: c['mtu'] as int? ?? 1420,
          reserved: _parseReservedFromJson(c['reserved']),
          jc: c['jc'] as int? ?? 4,
          jmin: c['jmin'] as int? ?? 40,
          jmax: c['jmax'] as int? ?? 70,
          s1: c['s1'] as int? ?? 0,
          s2: c['s2'] as int? ?? 0,
          s3: c['s3'] as int? ?? 0,
          s4: c['s4'] as int? ?? 0,
          h1: _headerValue(c['h1'], 1),
          h2: _headerValue(c['h2'], 2),
          h3: _headerValue(c['h3'], 3),
          h4: _headerValue(c['h4'], 4),
        );
      } on ParseException {
        rethrow;
      } catch (_) {
        // Fall through to standard URI parsing
      }
    }

    final addresses = (p['address'] ?? '')
        .split(',')
        .where((s) => s.isNotEmpty)
        .toList();
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
      h1: _headerValue(p['h1'] ?? p['H1'], 1),
      h2: _headerValue(p['h2'] ?? p['H2'], 2),
      h3: _headerValue(p['h3'] ?? p['H3'], 3),
      h4: _headerValue(p['h4'] ?? p['H4'], 4),
    );
  }

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

  AmneziaWGConfig _parseIni(String raw) {
    final lines = raw
        .replaceFirst('\uFEFF', '')
        .split('\n')
        .map((l) => l.trim())
        .toList();
    final iface = <String, String>{};
    final peer = <String, String>{};
    var section = '';
    var name = '';
    for (final line in lines) {
      if (line.startsWith('[Interface]')) {
        section = 'iface';
        continue;
      }
      if (line.startsWith('[Peer]')) {
        section = 'peer';
        continue;
      }
      if (line.isEmpty) continue;
      // Parse # Name: comment for friendly tunnel name
      if (line.startsWith('#')) {
        final nameMatch = RegExp(
          r'^#\s*Name:\s*(.+)$',
          caseSensitive: false,
        ).firstMatch(line);
        if (nameMatch != null) name = nameMatch.group(1)!.trim();
        continue;
      }
      final eqIdx = line.indexOf('=');
      if (eqIdx < 0) continue;
      final k = line.substring(0, eqIdx).trim().toLowerCase();
      final v = line.substring(eqIdx + 1).trim();
      if (section == 'iface')
        iface[k] = v;
      else if (section == 'peer')
        peer[k] = v;
    }

    _checkSupportedParameters(iface);
    _checkSupportedParameters(peer);
    validateWgQuickKeys(iface, peer);
    final (host, port) = parseWgQuickEndpoint(peer['endpoint'] ?? '');

    return AmneziaWGConfig(
      name: name,
      host: host,
      port: port,
      privateKey: iface['privatekey'] ?? '',
      publicKey: peer['publickey'] ?? '',
      presharedKey: peer['presharedkey'] ?? '',
      addresses: (iface['address'] ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      dns: (iface['dns'] ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      mtu: int.tryParse(iface['mtu'] ?? '') ?? 1420,
      jc: int.tryParse(iface['jc'] ?? '') ?? 4,
      jmin: int.tryParse(iface['jmin'] ?? '') ?? 40,
      jmax: int.tryParse(iface['jmax'] ?? '') ?? 70,
      s1: int.tryParse(iface['s1'] ?? '') ?? 0,
      s2: int.tryParse(iface['s2'] ?? '') ?? 0,
      s3: int.tryParse(iface['s3'] ?? '') ?? 0,
      s4: int.tryParse(iface['s4'] ?? '') ?? 0,
      h1: _headerValue(iface['h1'], 1),
      h2: _headerValue(iface['h2'], 2),
      h3: _headerValue(iface['h3'], 3),
      h4: _headerValue(iface['h4'], 4),
    );
  }
}
