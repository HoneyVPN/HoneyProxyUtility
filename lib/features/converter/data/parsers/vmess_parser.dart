import 'dart:convert';

import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

class VmessParser extends BaseProxyParser<VmessConfig> {
  const VmessParser();

  @override
  String get scheme => 'vmess://';

  @override
  bool canParse(String rawLink) => rawLink.startsWith('vmess://');

  @override
  VmessConfig parse(String rawLink) {
    final encoded = rawLink.substring(8);
    if (encoded.isEmpty) throw const ParseException('Empty vmess payload');

    final padded = _addPadding(encoded);
    late String jsonStr;
    try {
      jsonStr = utf8.decode(base64.decode(padded));
    } catch (_) {
      throw ParseException('Invalid base64 in vmess link: $encoded');
    }

    late Map<String, dynamic> m;
    try {
      m = json.decode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      throw const ParseException('vmess payload is not valid JSON');
    }

    final host = (m['add'] as String?)?.trim() ?? '';
    if (host.isEmpty) throw const ParseException('vmess: missing server address');

    return VmessConfig(
      name: (m['ps'] as String?) ?? '',
      host: host,
      port: _parseInt(m['port']),
      uuid: (m['id'] as String?) ?? '',
      alterId: _parseInt(m['aid']),
      security: (m['scy'] as String?) ?? 'auto',
      network: (m['net'] as String?) ?? 'tcp',
      path: (m['path'] as String?) ?? '/',
      wsHost: (m['host'] as String?) ?? '',
      tls: (m['tls'] as String?) ?? '',
      sni: (m['sni'] as String?) ?? '',
      alpn: (m['alpn'] as String?) ?? '',
      fingerprint: (m['fp'] as String?) ?? '',
    );
  }

  static String _addPadding(String s) {
    final mod = s.length % 4;
    if (mod == 0) return s;
    return s + '=' * (4 - mod);
  }

  static int _parseInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    return int.tryParse(v.toString()) ?? 0;
  }
}
