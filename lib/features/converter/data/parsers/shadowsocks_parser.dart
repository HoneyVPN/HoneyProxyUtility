import 'dart:convert';

import 'base_parser.dart';
import '../../domain/entities/parsed_proxy.dart';

class ShadowsocksParser extends BaseProxyParser<ShadowsocksConfig> {
  const ShadowsocksParser();

  @override
  String get scheme => 'ss://';

  @override
  bool canParse(String rawLink) => rawLink.startsWith('ss://');

  @override
  ShadowsocksConfig parse(String rawLink) {
    // SIP002: ss://BASE64URL(method:password)@host:port?plugin#name
    // Legacy:  ss://BASE64(method:password@host:port)#name
    final withoutScheme = rawLink.substring(5);
    final fragIdx = withoutScheme.indexOf('#');
    final name = fragIdx >= 0
        ? BaseProxyParser.decodeUri(withoutScheme.substring(fragIdx + 1))
        : '';
    final main = fragIdx >= 0 ? withoutScheme.substring(0, fragIdx) : withoutScheme;

    final atIdx = main.lastIndexOf('@');
    if (atIdx < 0) {
      return _parseLegacy(main, name);
    }
    return _parseSip002(main, name, atIdx);
  }

  ShadowsocksConfig _parseSip002(String main, String name, int atIdx) {
    final userInfoB64 = main.substring(0, atIdx);
    final hostPart = main.substring(atIdx + 1);

    String method;
    String password;
    try {
      final decoded = utf8.decode(base64.decode(_addPadding(userInfoB64)));
      final colonIdx = decoded.indexOf(':');
      if (colonIdx < 0) throw '';
      method = decoded.substring(0, colonIdx);
      password = decoded.substring(colonIdx + 1);
    } catch (_) {
      // SIP002 percent-encoded userinfo
      final colonIdx = userInfoB64.indexOf(':');
      if (colonIdx >= 0) {
        method = Uri.decodeComponent(userInfoB64.substring(0, colonIdx));
        password = Uri.decodeComponent(userInfoB64.substring(colonIdx + 1));
      } else {
        method = userInfoB64;
        password = '';
      }
    }

    final qIdx = hostPart.indexOf('?');
    final hostPortStr = qIdx >= 0 ? hostPart.substring(0, qIdx) : hostPart;
    final query = qIdx >= 0 ? Uri.splitQueryString(hostPart.substring(qIdx + 1)) : <String, String>{};

    final colonIdx = hostPortStr.lastIndexOf(':');
    final host = colonIdx >= 0 ? hostPortStr.substring(0, colonIdx) : hostPortStr;
    final port = colonIdx >= 0 ? int.tryParse(hostPortStr.substring(colonIdx + 1)) ?? 8388 : 8388;

    final plugin = query['plugin'] ?? '';
    final pluginParts = plugin.split(';');
    return ShadowsocksConfig(
      name: name,
      host: host,
      port: port,
      method: method.toLowerCase(),
      password: password,
      plugin: pluginParts.isNotEmpty ? pluginParts.first : '',
      pluginOpts: pluginParts.length > 1 ? pluginParts.sublist(1).join(';') : '',
    );
  }

  ShadowsocksConfig _parseLegacy(String encoded, String name) {
    final String decoded;
    try {
      decoded = utf8.decode(base64.decode(_addPadding(encoded)));
    } catch (_) {
      throw ParseException('SS legacy: cannot decode base64: $encoded');
    }
    final atIdx = decoded.lastIndexOf('@');
    if (atIdx < 0) throw const ParseException('SS legacy: missing @ separator');

    final userInfo = decoded.substring(0, atIdx);
    final hostPort = decoded.substring(atIdx + 1);
    final colonIdx = userInfo.indexOf(':');
    final method = colonIdx >= 0 ? userInfo.substring(0, colonIdx) : userInfo;
    final password = colonIdx >= 0 ? userInfo.substring(colonIdx + 1) : '';

    final hColonIdx = hostPort.lastIndexOf(':');
    final host = hColonIdx >= 0 ? hostPort.substring(0, hColonIdx) : hostPort;
    final port = hColonIdx >= 0 ? int.tryParse(hostPort.substring(hColonIdx + 1)) ?? 8388 : 8388;

    return ShadowsocksConfig(
      name: name,
      host: host,
      port: port,
      method: method.toLowerCase(),
      password: password,
      plugin: '',
      pluginOpts: '',
    );
  }

  static String _addPadding(String s) {
    final mod = s.length % 4;
    if (mod == 0) return s;
    return s + '=' * (4 - mod);
  }
}
