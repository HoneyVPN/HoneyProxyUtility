import 'base_parser.dart';
import 'vmess_parser.dart';
import 'vless_parser.dart';
import 'trojan_parser.dart';
import 'shadowsocks_parser.dart';
import 'hysteria2_parser.dart';
import 'tuic_parser.dart';
import 'wireguard_parser.dart';
import 'naive_parser.dart';
import 'shadowtls_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

/// Routes a raw proxy URI to the appropriate parser.
/// Parsers are checked in order; first match wins.
class LinkDispatcher {
  static const _parsers = <BaseProxyParser>[
    VlessParser(),
    VmessParser(),
    Hysteria2Parser(),
    TuicParser(),
    TrojanParser(),
    ShadowsocksParser(),
    WireGuardParser(),
    NaiveParser(),
    ShadowTlsParser(),
  ];

  const LinkDispatcher();

  /// Parse a single proxy link. Throws [UnsupportedProtocolException] if
  /// no parser recognises the scheme.
  ParsedProxy dispatch(String rawLink) {
    final trimmed = rawLink.trim();
    if (trimmed.isEmpty) throw const ParseException('Empty link');

    for (final parser in _parsers) {
      if (parser.canParse(trimmed)) {
        return parser.parse(trimmed);
      }
    }
    throw const UnsupportedProtocolException();
  }

  /// Parse multiple links separated by newlines (e.g. from clipboard).
  /// Silently skips unparseable lines and returns successfully parsed ones.
  List<ParsedProxy> dispatchMultiple(String rawText) {
    final results = <ParsedProxy>[];
    for (final line in rawText.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        results.add(dispatch(trimmed));
      } catch (_) {
        // skip unparseable lines
      }
    }
    return results;
  }

  bool canParse(String rawLink) {
    final trimmed = rawLink.trim();
    return _parsers.any((p) => p.canParse(trimmed));
  }
}
