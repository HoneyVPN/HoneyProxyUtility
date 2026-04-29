import 'dart:convert';

import '../../../converter/domain/entities/parsed_proxy.dart';

enum RoutingMode { global, bypassRU, rules }
enum TunStack { system, gvisor, mixed }
enum DnsPreset { cloudflare, google, custom }
enum LogLevel { trace, debug, info, warn, error }

class AppSettings {
  final RoutingMode routingMode;
  final TunStack tunStack;
  final DnsPreset dnsPreset;
  final String customDns;
  final bool blockAds;
  final bool enableFakeip;
  final LogLevel logLevel;
  final int socksPort;
  final int httpPort;

  const AppSettings({
    this.routingMode = RoutingMode.bypassRU,
    this.tunStack = TunStack.mixed,
    this.dnsPreset = DnsPreset.cloudflare,
    this.customDns = '',
    this.blockAds = true,
    this.enableFakeip = true,
    this.logLevel = LogLevel.warn,
    this.socksPort = 2080,
    this.httpPort = 2081,
  });
}

class SingboxConfigGenerator {
  const SingboxConfigGenerator();

  /// Generate a full sing-box JSON config for the given proxy and settings.
  String generate(ParsedProxy proxy, AppSettings settings) {
    final config = {
      'log': _log(settings),
      'dns': _dns(settings),
      'inbounds': _inbounds(settings),
      'outbounds': [
        _outbound(proxy),
        _direct(),
        _block(),
        _dns_out(),
      ],
      'route': _route(settings),
    };
    return jsonEncode(config);
  }

  Map<String, dynamic> _log(AppSettings s) => {
    'level': s.logLevel.name,
    'timestamp': true,
  };

  Map<String, dynamic> _dns(AppSettings s) {
    final remoteDns = switch (s.dnsPreset) {
      DnsPreset.cloudflare => 'tls://1.1.1.1',
      DnsPreset.google => 'tls://8.8.8.8',
      DnsPreset.custom => s.customDns.isNotEmpty ? s.customDns : 'tls://1.1.1.1',
    };

    final rules = <Map<String, dynamic>>[
      {'outbound': 'any', 'server': 'local-dns'},
    ];
    if (s.routingMode == RoutingMode.bypassRU || s.routingMode == RoutingMode.rules) {
      rules.add({'rule_set': 'geosite-cn', 'server': 'local-dns'});
    }

    return {
      'servers': [
        {'tag': 'remote-dns', 'address': remoteDns, 'detour': 'proxy'},
        {'tag': 'local-dns', 'address': 'https://223.5.5.5/dns-query', 'detour': 'direct'},
        if (s.enableFakeip) {
          'tag': 'fakeip-dns',
          'address': 'fakeip',
        },
        {'tag': 'block-dns', 'address': 'rcode://success'},
      ],
      if (s.enableFakeip)
        'fakeip': {
          'enabled': true,
          'inet4_range': '198.18.0.0/15',
          'inet6_range': 'fc00::/18',
        },
      'rules': [
        ...rules,
        if (s.blockAds) {'rule_set': 'geosite-category-ads-all', 'server': 'block-dns'},
        if (s.enableFakeip) {'query_type': ['A', 'AAAA'], 'server': 'fakeip-dns'},
      ],
      'final': 'remote-dns',
      'independent_cache': true,
    };
  }

  List<Map<String, dynamic>> _inbounds(AppSettings s) => [
    {
      'type': 'tun',
      'tag': 'tun-in',
      'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
      'mtu': 9000,
      'auto_route': true,
      'strict_route': true,
      'stack': s.tunStack.name,
      'sniff': true,
      'sniff_override_destination': false,
    },
    {
      'type': 'socks',
      'tag': 'socks-in',
      'listen': '127.0.0.1',
      'listen_port': s.socksPort,
      'sniff': true,
    },
    {
      'type': 'http',
      'tag': 'http-in',
      'listen': '127.0.0.1',
      'listen_port': s.httpPort,
      'sniff': true,
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

  // --- VLESS ---
  Map<String, dynamic> _vless(VlessConfig c) => {
    'type': 'vless',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'uuid': c.uuid,
    if (c.flow.isNotEmpty) 'flow': c.flow,
    ..._tlsBlock(c.security, c.sni, c.fingerprint, pbk: c.publicKey, sid: c.shortId),
    if (c.transport != 'tcp') 'transport': _transport(c.transport, c.path, c.transportHost, c.grpcServiceName),
    'packet_encoding': 'xudp',
  };

  // --- VMess ---
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

  // --- Trojan ---
  Map<String, dynamic> _trojan(TrojanConfig c) => {
    'type': 'trojan',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'password': c.password,
    ..._tlsBlock(c.security, c.sni, c.fingerprint, alpn: c.alpn),
    if (c.transport != 'tcp') 'transport': _transport(c.transport, c.path, c.transportHost, ''),
  };

  // --- Shadowsocks ---
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

  // --- Hysteria2 ---
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

  // --- TUIC ---
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

  // --- WireGuard ---
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

  // --- NaïveProxy ---
  Map<String, dynamic> _naive(NaiveConfig c) => {
    'type': 'http',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'username': c.username,
    'password': c.password,
    'tls': {
      'enabled': true,
    },
  };

  // --- ShadowTLS ---
  Map<String, dynamic> _shadowtls(ShadowTlsConfig c) {
    final inner = _outbound(c.innerProxy)..['tag'] = 'shadowtls-inner';
    return {
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
  }

  // --- TLS block helper ---
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

  // --- Transport block helper ---
  Map<String, dynamic> _transport(String type, String path, String host, String serviceName) {
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

  Map<String, dynamic> _direct() => {'type': 'direct', 'tag': 'direct'};
  Map<String, dynamic> _block() => {'type': 'block', 'tag': 'block'};
  Map<String, dynamic> _dns_out() => {'type': 'dns', 'tag': 'dns-out'};

  Map<String, dynamic> _route(AppSettings s) {
    final rules = <Map<String, dynamic>>[
      {'protocol': 'dns', 'outbound': 'dns-out'},
      {'ip_is_private': true, 'outbound': 'direct'},
    ];

    final ruleSets = <Map<String, dynamic>>[];

    if (s.routingMode == RoutingMode.bypassRU || s.routingMode == RoutingMode.rules) {
      rules.add({'rule_set': 'geosite-cn', 'outbound': 'direct'});
      rules.add({'rule_set': 'geoip-cn', 'outbound': 'direct'});
      ruleSets.addAll([
        {
          'type': 'remote',
          'tag': 'geosite-cn',
          'format': 'binary',
          'url': 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs',
          'download_detour': 'direct',
          'update_interval': '7d',
        },
        {
          'type': 'remote',
          'tag': 'geoip-cn',
          'format': 'binary',
          'url': 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs',
          'download_detour': 'direct',
          'update_interval': '7d',
        },
      ]);
    }

    if (s.blockAds) {
      rules.add({'rule_set': 'geosite-category-ads-all', 'outbound': 'block'});
      ruleSets.add({
        'type': 'remote',
        'tag': 'geosite-category-ads-all',
        'format': 'binary',
        'url': 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs',
        'download_detour': 'direct',
        'update_interval': '7d',
      });
    }

    return {
      'rules': rules,
      if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
      'final': s.routingMode == RoutingMode.global ? 'proxy' : 'proxy',
      'auto_detect_interface': true,
    };
  }
}
