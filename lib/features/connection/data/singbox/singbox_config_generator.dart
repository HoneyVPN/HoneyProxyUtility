import 'dart:convert';

import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../settings/data/models/app_settings.dart';

class SingboxConfigGenerator {
  /// [geoPaths] — map of filename → absolute path from [GeoDataManager.ensureReady].
  /// If null or a key is missing, falls back to remote download.
  const SingboxConfigGenerator({this.geoPaths});

  final Map<String, String>? geoPaths;

  String generate(ParsedProxy proxy, AppSettings settings) {
    final proxyOut = _outbound(proxy);
    if (settings.multiplexerEnabled) {
      proxyOut['multiplex'] = {
        'enabled': true,
        'protocol': 'smux',
        'max_connections': 4,
        'min_streams': 4,
      };
    }
    final outbounds = <Map<String, dynamic>>[proxyOut];

    // ShadowTLS requires the inner proxy as a separate named outbound
    if (proxy is ShadowTlsConfig) {
      final inner = _outbound(proxy.innerProxy);
      inner['tag'] = 'shadowtls-inner';
      outbounds.add(inner);
    }

    outbounds.addAll([_direct(), _block()]);

    final config = {
      'log': _log(settings),
      'dns': _dns(settings),
      'inbounds': _inbounds(settings),
      'outbounds': outbounds,
      'route': _route(settings),
    };
    return jsonEncode(config);
  }

  Map<String, dynamic> _log(AppSettings s) => {
    'level': s.logLevel.name,
    'timestamp': true,
  };

  Map<String, dynamic> _dns(AppSettings s) {
    final remoteDnsServer = switch (s.dnsPreset) {
      DnsPreset.cloudflare => {'type': 'tls', 'server': '1.1.1.1'},
      DnsPreset.google     => {'type': 'tls', 'server': '8.8.8.8'},
      DnsPreset.adguard    => {'type': 'tls', 'server': '94.140.14.14'},
      DnsPreset.custom     => _parseDnsAddress(s.customDnsUrl),
    };

    final rules = <Map<String, dynamic>>[
      {'outbound': 'any', 'server': 'local-dns'},
    ];
    if (s.routingMode == RoutingMode.bypassRU || s.routingMode == RoutingMode.rules) {
      rules.add({'rule_set': 'ru', 'server': 'local-dns'});
    }

    return {
      'servers': [
        {
          'tag': 'remote-dns',
          ...remoteDnsServer,
          'detour': 'proxy',
        },
        {
          'tag': 'local-dns',
          'type': 'https',
          'server': '223.5.5.5',
          'path': '/dns-query',
          'detour': 'direct',
        },
        if (s.enableFakeip) {
          'tag': 'fakeip-dns',
          'type': 'fakeip',
          'inet4_range': '198.18.0.0/15',
          'inet6_range': 'fc00::/18',
        },
      ],
      'rules': [
        ...rules,
        if (s.blockAds) {'rule_set': 'geosite-category-ads-all', 'action': 'reject'},
        if (s.enableFakeip) {'query_type': ['A', 'AAAA'], 'server': 'fakeip-dns'},
      ],
      'final': 'remote-dns',
      'independent_cache': true,
    };
  }

  Map<String, dynamic> _parseDnsAddress(String url) {
    if (!_isValidDnsUrl(url)) return {'type': 'tls', 'server': '1.1.1.1'};
    try {
      final uri = Uri.parse(url);
      if (uri.scheme == 'https') {
        return {
          'type': 'https',
          'server': uri.host,
          'path': uri.path.isEmpty ? '/dns-query' : uri.path,
        };
      }
      return {'type': 'tls', 'server': uri.host.isEmpty ? '1.1.1.1' : uri.host};
    } catch (_) {
      return {'type': 'tls', 'server': '1.1.1.1'};
    }
  }

  List<Map<String, dynamic>> _inbounds(AppSettings s) => [
    {
      'type': 'tun',
      'tag': 'tun-in',
      'address': ['198.18.0.1/16', 'fdfe:dcba:9876::1/126'],
      'mtu': 9000,
      'auto_route': true,
      'strict_route': true,
      'stack': s.tunStack.name,
    },
    {
      'type': 'socks',
      'tag': 'socks-in',
      'listen': s.allowLanConnections ? '0.0.0.0' : '127.0.0.1',
      'listen_port': s.socksPort,
    },
    {
      'type': 'http',
      'tag': 'http-in',
      'listen': s.allowLanConnections ? '0.0.0.0' : '127.0.0.1',
      'listen_port': s.httpPort,
    },
  ];

  Map<String, dynamic> _outbound(ParsedProxy proxy) => switch (proxy) {
    VlessConfig c   => _vless(c),
    VmessConfig c   => _vmess(c),
    TrojanConfig c  => _trojan(c),
    ShadowsocksConfig c => _shadowsocks(c),
    Hysteria2Config c => _hysteria2(c),
    TuicConfig c    => _tuic(c),
    WireGuardConfig c => _wireguard(c),
    NaiveConfig c   => _naive(c),
    ShadowTlsConfig c => _shadowtls(c),
  };

  Map<String, dynamic> _vless(VlessConfig c) => {
    'type': 'vless',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'uuid': c.uuid,
    if (c.flow.isNotEmpty) 'flow': c.flow,
    ..._tlsBlock(c.security, c.sni, c.fingerprint, pbk: c.publicKey, sid: c.shortId),
    if (c.transport != 'tcp') 'transport': _transport(c.transport, c.path, c.transportHost, c.grpcServiceName, c.xhttpMode, c.xPaddingBytes),
    'packet_encoding': 'xudp',
  };

  Map<String, dynamic> _vmess(VmessConfig c) => {
    'type': 'vmess',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'uuid': c.uuid,
    'alter_id': c.alterId,
    'security': c.security,
    if (c.tls == 'tls') ..._tlsBlock('tls', c.sni, c.fingerprint),
    if (c.network != 'tcp') 'transport': _transport(c.network, c.path, c.wsHost, ''),
    'packet_encoding': 'xudp',
  };

  Map<String, dynamic> _trojan(TrojanConfig c) => {
    'type': 'trojan',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'password': c.password,
    ..._tlsBlock(c.security, c.sni, c.fingerprint, alpn: c.alpn),
    if (c.transport != 'tcp') 'transport': _transport(c.transport, c.path, c.transportHost, ''),
  };

  Map<String, dynamic> _shadowsocks(ShadowsocksConfig c) => {
    'type': 'shadowsocks',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'method': c.method,
    'password': c.password,
    if (c.plugin.isNotEmpty) 'plugin': c.plugin,
    if (c.pluginOpts.isNotEmpty) 'plugin_opts': c.pluginOpts,
    'udp_over_tcp': false,
  };

  Map<String, dynamic> _hysteria2(Hysteria2Config c) => {
    'type': 'hysteria2',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    if (c.auth.isNotEmpty) 'password': c.auth,
    'tls': {
      'enabled': true,
      if (c.sni.isNotEmpty) 'server_name': c.sni,
      'insecure': c.insecure,
      if (c.pinSha256.isNotEmpty) 'pinned_peer_certificate_chain_sha256': [c.pinSha256],
    },
    if (c.obfs.isNotEmpty) 'obfs': {
      'type': c.obfs,
      'password': c.obfsPassword,
    },
  };

  Map<String, dynamic> _tuic(TuicConfig c) => {
    'type': 'tuic',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'uuid': c.uuid,
    'password': c.password,
    'congestion_control': c.congestionControl,
    'udp_relay_mode': c.udpRelayMode,
    'tls': {
      'enabled': true,
      if (c.sni.isNotEmpty) 'server_name': c.sni,
      if (c.alpn.isNotEmpty) 'alpn': c.alpn.split(','),
      'insecure': c.allowInsecure,
    },
  };

  Map<String, dynamic> _wireguard(WireGuardConfig c) => {
    'type': 'wireguard',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'private_key': c.privateKey,
    'peer_public_key': c.publicKey,
    if (c.presharedKey.isNotEmpty) 'pre_shared_key': c.presharedKey,
    'local_address': c.addresses,
    if (c.reserved != null) 'reserved': c.reserved,
    'mtu': c.mtu,
  };

  Map<String, dynamic> _naive(NaiveConfig c) => {
    'type': 'http',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'username': c.username,
    'password': c.password,
    'tls': {'enabled': true},
  };

  // ShadowTLS outer outbound; the inner outbound is added separately in generate()
  Map<String, dynamic> _shadowtls(ShadowTlsConfig c) => {
    'type': 'shadowtls',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'version': c.version,
    'password': c.password,
    'tls': {
      'enabled': true,
      if (c.sni.isNotEmpty) 'server_name': c.sni,
    },
    'detour': 'shadowtls-inner',
  };

  Map<String, dynamic> _tlsBlock(
    String security,
    String sni,
    String fp, {
    String pbk = '',
    String sid = '',
    String alpn = '',
  }) {
    if (security == 'none' || security.isEmpty) return {};
    final tls = <String, dynamic>{
      'enabled': true,
      if (sni.isNotEmpty) 'server_name': sni,
      if (alpn.isNotEmpty) 'alpn': alpn.split(','),
      if (fp.isNotEmpty) 'utls': {'enabled': true, 'fingerprint': fp},
    };
    if (security == 'reality') {
      tls['reality'] = {
        'enabled': true,
        'public_key': pbk,
        'short_id': sid,
      };
    }
    return {'tls': tls};
  }

  Map<String, dynamic> _transport(String type, String path, String host, String serviceName, [String mode = '', String xPadding = '']) {
    switch (type) {
      case 'ws':
      case 'websocket':
        return {
          'type': 'ws',
          if (path.isNotEmpty) 'path': path,
          if (host.isNotEmpty) 'headers': {'Host': host},
          'max_early_data': 2048,
          'early_data_header_name': 'Sec-WebSocket-Protocol',
        };
      case 'h2':
      case 'http':
        return {
          'type': 'http',
          if (path.isNotEmpty) 'path': path,
          if (host.isNotEmpty) 'host': [host],
        };
      case 'grpc':
        return {
          'type': 'grpc',
          if (serviceName.isNotEmpty) 'service_name': serviceName,
          'idle_timeout': '15s',
          'ping_timeout': '15s',
          'permit_without_stream': false,
        };
      case 'xhttp':
        return {
          'type': 'xhttp',
          if (path.isNotEmpty) 'path': path,
          if (host.isNotEmpty) 'host': host,
          if (mode.isNotEmpty) 'mode': mode,
          'x_padding_bytes': xPadding.isNotEmpty ? xPadding : '100-1000',
        };
      case 'httpupgrade':
        return {
          'type': 'httpupgrade',
          if (path.isNotEmpty) 'path': path,
          if (host.isNotEmpty) 'host': host,
        };
      default:
        return {'type': 'tcp'};
    }
  }

  /// Builds a local rule-set entry if [geoPaths] has the file,
  /// otherwise falls back to a remote URL from runetfreedom releases.
  Map<String, dynamic> _ruleSet(String tag, String filename) {
    final localPath = geoPaths?[filename];
    if (localPath != null) {
      return {'type': 'local', 'tag': tag, 'format': 'binary', 'path': localPath};
    }
    const base = 'https://github.com/runetfreedom/russia-blocked-geoip/raw/release/srs';
    const adBase = 'https://github.com/SagerNet/sing-geosite/raw/rule-set';
    final url = filename == 'geosite-category-ads-all.srs'
        ? '$adBase/$filename'
        : '$base/$filename';
    return {
      'type': 'remote',
      'tag': tag,
      'format': 'binary',
      'url': url,
      'download_detour': 'direct',
      'update_interval': '7d',
    };
  }

  static bool _isValidDnsUrl(String url) {
    if (url.isEmpty) return false;
    try {
      final uri = Uri.parse(url);
      return uri.hasScheme && uri.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  String _ipStrategy(IpType t) => switch (t) {
    IpType.ipv4 => 'ipv4_only',
    IpType.ipv6 => 'ipv6_only',
    IpType.both => 'prefer_ipv4',
  };

  Map<String, dynamic> _direct() => {'type': 'direct', 'tag': 'direct'};
  Map<String, dynamic> _block() => {'type': 'block', 'tag': 'block'};

  Map<String, dynamic> _route(AppSettings s) {
    final rules = <Map<String, dynamic>>[
      {'action': 'sniff'},
      if (s.fragmentationEnabled) {'action': 'tls_fragment'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      {'ip_is_private': true, 'outbound': 'direct'},
    ];

    final ruleSets = <Map<String, dynamic>>[];

    if (s.routingMode == RoutingMode.bypassRU || s.routingMode == RoutingMode.rules) {
      // Blocked sites → proxy (bypass Roskomnadzor restrictions)
      rules.add({'rule_set': 'ru-blocked',           'outbound': 'proxy'});
      rules.add({'rule_set': 'ru-blocked-community', 'outbound': 'proxy'});
      rules.add({'rule_set': 're-filter',            'outbound': 'proxy'});
      // Russian IPs → direct
      rules.add({'rule_set': 'ru', 'outbound': 'direct'});
      ruleSets.addAll([
        _ruleSet('ru-blocked',           'ru-blocked.srs'),
        _ruleSet('ru-blocked-community', 'ru-blocked-community.srs'),
        _ruleSet('re-filter',            're-filter.srs'),
        _ruleSet('ru',                   'ru.srs'),
      ]);
    }

    if (s.blockAds) {
      rules.add({'rule_set': 'geosite-category-ads-all', 'outbound': 'block'});
      ruleSets.add(_ruleSet('geosite-category-ads-all', 'geosite-category-ads-all.srs'));
    }

    return {
      'rules': rules,
      if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
      'final': 'proxy',
      'auto_detect_interface': true,
    };
  }

  String generateForAndroid(ParsedProxy proxy, AppSettings settings) {
    final proxyOut = _outbound(proxy);
    if (settings.multiplexerEnabled) {
      proxyOut['multiplex'] = {
        'enabled': true,
        'protocol': 'smux',
        'max_connections': 4,
        'min_streams': 4,
      };
    }
    final outbounds = <Map<String, dynamic>>[proxyOut];

    if (proxy is ShadowTlsConfig) {
      final inner = _outbound(proxy.innerProxy);
      inner['tag'] = 'shadowtls-inner';
      outbounds.add(inner);
    }

    outbounds.addAll([_direct(), _block()]);

    final config = {
      'log': _log(settings),
      'dns': _dns(settings),
      'inbounds': _inboundsForAndroid(),
      'outbounds': outbounds,
      'route': _routeForAndroid(settings),
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:9090',
          'store_selected': false,
        },
      },
    };
    return jsonEncode(config);
  }

  List<Map<String, dynamic>> _inboundsForAndroid() => [
    {
      'type': 'tun',
      'tag': 'tun-in',
      // interface_name is injected at runtime by HoneyProxyVpnService
      'mtu': 9000,
      'stack': 'mixed',
    },
  ];

  Map<String, dynamic> _routeForAndroid(AppSettings s) {
    final rules = <Map<String, dynamic>>[
      {'action': 'sniff'},
      if (s.fragmentationEnabled) {'action': 'tls_fragment'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      {'ip_is_private': true, 'outbound': 'direct'},
    ];

    final ruleSets = <Map<String, dynamic>>[];

    if (s.routingMode == RoutingMode.bypassRU || s.routingMode == RoutingMode.rules) {
      rules.add({'rule_set': 'ru-blocked',           'outbound': 'proxy'});
      rules.add({'rule_set': 'ru-blocked-community', 'outbound': 'proxy'});
      rules.add({'rule_set': 're-filter',            'outbound': 'proxy'});
      rules.add({'rule_set': 'ru', 'outbound': 'direct'});
      ruleSets.addAll([
        _ruleSet('ru-blocked',           'ru-blocked.srs'),
        _ruleSet('ru-blocked-community', 'ru-blocked-community.srs'),
        _ruleSet('re-filter',            're-filter.srs'),
        _ruleSet('ru',                   'ru.srs'),
      ]);
    }

    if (s.blockAds) {
      rules.add({'rule_set': 'geosite-category-ads-all', 'outbound': 'block'});
      ruleSets.add(_ruleSet('geosite-category-ads-all', 'geosite-category-ads-all.srs'));
    }

    return {
      'rules': rules,
      if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
      'final': 'proxy',
      // Android: no auto_detect_interface — routing handled by VPN service
    };
  }
}