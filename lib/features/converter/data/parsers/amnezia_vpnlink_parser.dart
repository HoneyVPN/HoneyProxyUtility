import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'amneziawg_parser.dart';
import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

/// Parses Amnezia `vpn://` share links.
///
/// Format: `vpn://` + base64url( uint32BE(uncompressedSize) + zlib(JSON) )
///
/// Outer JSON envelope:
/// ```json
/// {
///   "containers": [{"container": "amnezia-awg", "awg": {
///       "last_config": "{\"config\":\"[Interface]\\n...\", ...}"
///   }}],
///   "hostName": "1.2.3.4",
///   "description": "My VPN"
/// }
/// ```
/// `last_config` is itself a JSON-encoded string whose "config" key holds the
/// wg-quick INI text with AWG obfuscation fields.
class AmneziaVpnLinkParser extends BaseProxyParser<AmneziaWGConfig> {
  const AmneziaVpnLinkParser();

  @override
  String get scheme => 'vpn://';

  @override
  bool canParse(String rawLink) => rawLink.startsWith('vpn://');

  @override
  AmneziaWGConfig parse(String rawLink) {
    final encoded = rawLink.substring('vpn://'.length);
    final bytes = _decodeBase64Url(encoded);

    if (bytes.length < 4) throw const ParseException('vpn:// payload too short');

    // Skip 4-byte Qt big-endian uncompressed-size header
    final compressed = bytes.sublist(4);

    final Uint8List jsonBytes;
    try {
      jsonBytes = Uint8List.fromList(ZLibDecoder().convert(compressed));
    } catch (_) {
      throw const ParseException('vpn:// zlib decompression failed');
    }

    final Map<String, dynamic> envelope;
    try {
      envelope = json.decode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const ParseException('vpn:// JSON parse failed');
    }

    final description = envelope['description'] as String? ?? '';
    final hostName    = envelope['hostName']    as String? ?? '';

    final containers = envelope['containers'] as List<dynamic>? ?? [];
    for (final raw in containers) {
      final c    = raw as Map<String, dynamic>;
      final type = c['container'] as String? ?? '';

      if (type == 'amnezia-awg' || type == 'awg') {
        final awgMap   = c['awg'] as Map<String, dynamic>? ?? {};
        final lastConfig = awgMap['last_config'] as String? ?? '';

        // last_config is a JSON-encoded string: {"config":"[Interface]\n...", ...}
        final iniText = _extractIni(lastConfig);
        if (iniText.isNotEmpty) {
          final config = const AmneziaWGParser().parse(iniText);
          return AmneziaWGConfig(
            name: description,
            host: config.host.isNotEmpty ? config.host : hostName,
            port: config.port,
            privateKey: config.privateKey,
            publicKey: config.publicKey,
            presharedKey: config.presharedKey,
            addresses: config.addresses,
            dns: config.dns,
            mtu: config.mtu,
            reserved: config.reserved,
            jc: config.jc, jmin: config.jmin, jmax: config.jmax,
            s1: config.s1, s2: config.s2, s3: config.s3, s4: config.s4,
            h1: config.h1, h2: config.h2, h3: config.h3, h4: config.h4,
          );
        }
      }
    }

    throw const ParseException('vpn:// no supported container found (expected amnezia-awg)');
  }

  /// Extracts the wg-quick INI text from a `last_config` value which may be:
  /// - A plain INI string starting with `[Interface]` or `# Name:`
  /// - A JSON-encoded string: `{"config":"[Interface]\\n...", ...}`
  static String _extractIni(String lastConfig) {
    final trimmed = lastConfig.trim();
    if (trimmed.isEmpty) return '';

    // Already a plain INI?
    if (trimmed.startsWith('[') || trimmed.startsWith('#')) return trimmed;

    // Try to decode as JSON
    if (trimmed.startsWith('{')) {
      try {
        final inner = json.decode(trimmed) as Map<String, dynamic>;
        // AmneziaWG stores the actual INI in "config" key
        final cfg = inner['config'] as String?;
        if (cfg != null && cfg.isNotEmpty) return cfg;
      } catch (_) {}
    }

    return lastConfig;
  }

  static Uint8List _decodeBase64Url(String s) {
    final padded = s.padRight((s.length + 3) ~/ 4 * 4, '=');
    return base64Url.decode(padded);
  }
}
