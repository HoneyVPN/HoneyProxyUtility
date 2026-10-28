import 'dart:convert';

import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../settings/data/models/app_settings.dart';
import '../../domain/validation/play_tunnel_encryption.dart';
import 'provider_geo_bundle.dart';

enum SingboxConfigTarget { android, apple }

class SingboxConfigGenerator {
  /// [geoPaths] — map of filename → absolute path from [GeoDataManager.ensureReady].
  /// If null or a key is missing, falls back to remote download.
  const SingboxConfigGenerator({
    this.geoPaths,
    this.providerRouting,
    this.target = SingboxConfigTarget.android,
  });

  final Map<String, String>? geoPaths;
  final ProviderGeoBundle? providerRouting;
  final SingboxConfigTarget target;

  /// Validate target-specific fields before native or geodata preparation.
  void validateTargetCompatibility(ParsedProxy proxy) {
    if (target == SingboxConfigTarget.android) {
      validatePlayTunnelEncryption(proxy);
    }
    switch (proxy) {
      case WireGuardConfig c:
        _peerReserved(c.reserved);
      case AmneziaWGConfig c:
        _peerReserved(c.reserved);
      default:
        break;
    }
  }

  Map<String, dynamic> _peerReserved(List<int>? reserved) {
    // Android 1.14 removed packet-byte rewriting. Omit only values with no
    // effect; retain the imported profile for Apple's existing 1.13 core.
    if (target == SingboxConfigTarget.apple) {
      return {if (reserved != null) 'reserved': reserved};
    }
    if (reserved != null &&
        reserved.isNotEmpty &&
        (reserved.length != 3 || reserved.any((byte) => byte != 0))) {
      throw UnsupportedError(
        'WireGuard reserved bytes are unsupported by this Android core.',
      );
    }
    return const {};
  }

  Map<String, dynamic> _log(AppSettings s) => {
    'level': s.logLevel.name,
    'timestamp': true,
  };

  Map<String, dynamic> _dns(AppSettings s) {
    // DNS-over-HTTPS (DoH) is used instead of DoT because DoT (port 853) long-lived
    // TLS connections get EOF through many proxy servers, causing the "read response: EOF"
    // errors visible in sing-box logs. DoH over HTTP/2 is more reliable through proxies.
    final remoteDnsServer = switch (s.dnsPreset) {
      DnsPreset.cloudflare => {
        'type': 'https',
        'server': '1.1.1.1',
        'path': '/dns-query',
      },
      DnsPreset.google => {
        'type': 'https',
        'server': '8.8.8.8',
        'path': '/dns-query',
      },
      DnsPreset.adguard => {
        'type': 'https',
        'server': '94.140.14.14',
        'path': '/dns-query',
      },
      DnsPreset.custom => _parseDnsAddress(s.customDnsUrl),
    };

    return {
      'servers': [
        {'tag': 'remote-dns', ...remoteDnsServer, 'detour': 'proxy'},
        {
          'tag': 'local-dns',
          'type': 'https',
          'server': '223.5.5.5',
          'path': '/dns-query',
          'detour': 'direct',
        },
        if (s.enableFakeip)
          {
            'tag': 'fakeip-dns',
            'type': 'fakeip',
            'inet4_range': '198.18.0.0/15',
            'inet6_range': 'fc00::/18',
          },
      ],
      'rules': [
        // The bundled Russia set contains only IP ranges. A DNS rule using it
        // selects a transport before addresses exist, so it would send every
        // first A/AAAA query to local-dns. Keep it in traffic routing only.
        if (s.enableFakeip)
          {
            'query_type': ['A', 'AAAA'],
            'server': 'fakeip-dns',
          },
      ],
      'final': 'remote-dns',
      'strategy': _ipStrategy(s.preferredIpType),
      'independent_cache': true,
    };
  }

  Map<String, dynamic> _parseDnsAddress(String url) {
    final issue = AppSettings.customDnsIssue(url);
    if (issue != null) throw SettingsValidationException(issue);
    final uri = Uri.parse(url.trim());
    if (uri.scheme == 'https') {
      return {
        'type': 'https',
        'server': uri.host,
        if (uri.hasPort) 'server_port': uri.port,
        'path': uri.path.isEmpty ? '/dns-query' : uri.path,
      };
    }
    return {
      'type': 'tls',
      'server': uri.host,
      if (uri.hasPort) 'server_port': uri.port,
    };
  }

  Map<String, dynamic> _outbound(ParsedProxy proxy) => switch (proxy) {
    VlessConfig c => _vless(c),
    VmessConfig c => _vmess(c),
    TrojanConfig c => _trojan(c),
    ShadowsocksConfig c => _shadowsocks(c),
    Hysteria2Config c => _hysteria2(c),
    TuicConfig c => _tuic(c),
    WireGuardConfig _ => throw UnsupportedError(
      'WireGuard uses endpoint, not outbound',
    ),
    AmneziaWGConfig _ => throw UnsupportedError(
      'AWG uses endpoint, not outbound',
    ),
    NaiveConfig _ => throw UnsupportedError(
      'NaiveProxy is unavailable in this core build',
    ),
    ShadowTlsConfig c => _shadowtls(c),
  };

  Map<String, dynamic> _vless(VlessConfig c) {
    c.validateCoreCompatibility();
    return {
      'type': 'vless',
      'tag': 'proxy',
      'server': c.host,
      'server_port': c.port,
      'uuid': c.uuid,
      if (c.encryption.isNotEmpty && c.encryption != 'none')
        'encryption': c.encryption,
      if (c.flow.isNotEmpty) 'flow': c.flow,
      ..._tlsBlock(
        c.security,
        c.sni,
        c.effectiveFingerprint,
        pbk: c.publicKey,
        sid: c.shortId,
        alpn: c.effectiveAlpn.join(','),
        allowInsecure: c.allowInsecure,
      ),
      if (c.transport != 'tcp')
        'transport': _transport(
          c.transport,
          c.path,
          c.transportHost,
          c.grpcServiceName,
          c.xhttpMode,
          c.xPaddingBytes,
        ),
      'packet_encoding': 'xudp',
    };
  }

  Map<String, dynamic> _vmess(VmessConfig c) => {
    'type': 'vmess',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'uuid': c.uuid,
    'alter_id': c.alterId,
    'security': c.security,
    if (c.tls == 'tls') ..._tlsBlock('tls', c.sni, c.fingerprint),
    if (c.network != 'tcp')
      'transport': _transport(c.network, c.path, c.wsHost, ''),
    'packet_encoding': 'xudp',
  };

  Map<String, dynamic> _trojan(TrojanConfig c) => {
    'type': 'trojan',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'password': c.password,
    ..._tlsBlock(c.security, c.sni, c.fingerprint, alpn: c.alpn),
    if (c.transport != 'tcp')
      'transport': _transport(c.transport, c.path, c.transportHost, ''),
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

  Map<String, dynamic> _hysteria2(Hysteria2Config c) {
    c.validateCoreCompatibility();
    return {
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': c.host,
      'server_port': c.port,
      if (c.serverPorts.isNotEmpty) 'server_ports': c.serverPorts,
      if (c.hopInterval.isNotEmpty) 'hop_interval': c.hopInterval,
      if (c.auth.isNotEmpty) 'password': c.auth,
      'tls': {
        'enabled': true,
        if (c.sni.isNotEmpty) 'server_name': c.sni,
        'insecure': c.insecure,
      },
      if (c.obfs.isNotEmpty)
        'obfs': {'type': c.obfs, 'password': c.obfsPassword},
    };
  }

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

  // The legacy WireGuard outbound was removed in sing-box 1.13. The
  // endpoint preserves standard WireGuard semantics without AWG obfuscation.
  Map<String, dynamic> _wireguardEndpoint(WireGuardConfig c) => {
    'type': 'wireguard',
    'tag': 'proxy',
    'system': false,
    'address': c.addresses,
    'private_key': c.privateKey,
    'listen_port': 0,
    'mtu': c.mtu,
    'peers': [
      {
        'address': c.host,
        'port': c.port,
        'public_key': c.publicKey,
        'allowed_ips': ['0.0.0.0/0', '::/0'],
        if (c.presharedKey.isNotEmpty) 'pre_shared_key': c.presharedKey,
        ..._peerReserved(c.reserved),
      },
    ],
  };

  // AmneziaWG also uses endpoints, with its separate obfuscation options.
  Map<String, dynamic> _amneziaWGEndpoint(AmneziaWGConfig c) {
    final peer = <String, dynamic>{
      'address': c.host,
      'port': c.port,
      'public_key': c.publicKey,
      'allowed_ips': ['0.0.0.0/0', '::/0'],
      ..._peerReserved(c.reserved),
    };
    if (c.presharedKey.isNotEmpty) peer['pre_shared_key'] = c.presharedKey;

    final amnezia = <String, dynamic>{
      'jc': c.jc,
      'jmin': c.jmin,
      'jmax': c.jmax,
    };
    if (c.s1 != 0) amnezia['s1'] = c.s1;
    if (c.s2 != 0) amnezia['s2'] = c.s2;
    if (c.s3 != 0) amnezia['s3'] = c.s3;
    if (c.s4 != 0) amnezia['s4'] = c.s4;
    if (c.h1 != 0) amnezia['h1'] = c.h1;
    if (c.h2 != 0) amnezia['h2'] = c.h2;
    if (c.h3 != 0) amnezia['h3'] = c.h3;
    if (c.h4 != 0) amnezia['h4'] = c.h4;

    return {
      'type': 'wireguard',
      'tag': 'proxy',
      'address': c.addresses.isNotEmpty ? c.addresses : ['10.0.0.1/32'],
      'private_key': c.privateKey,
      'listen_port': 0,
      'peers': [peer],
      'mtu': c.mtu,
      'amnezia': amnezia,
    };
  }

  // ShadowTLS supplies transport for the inner Shadowsocks protocol. Traffic
  // enters the inner proxy, whose detour points to this outer TLS transport.
  Map<String, dynamic> _shadowtls(ShadowTlsConfig c) => {
    'type': 'shadowtls',
    'tag': 'shadowtls-out',
    'server': c.host,
    'server_port': c.port,
    'version': c.version,
    'password': c.password,
    'tls': {'enabled': true, if (c.sni.isNotEmpty) 'server_name': c.sni},
  };

  List<Map<String, dynamic>> _proxyOutbounds(ParsedProxy proxy) {
    if (proxy is! ShadowTlsConfig) return [_outbound(proxy)];
    if (proxy.innerProxy is! ShadowsocksConfig) {
      throw UnsupportedError('ShadowTLS requires a Shadowsocks inner proxy');
    }
    final inner = _outbound(proxy.innerProxy);
    inner['tag'] = 'proxy';
    inner['detour'] = 'shadowtls-out';
    return [inner, _shadowtls(proxy)];
  }

  Map<String, dynamic> _tlsBlock(
    String security,
    String sni,
    String fp, {
    String pbk = '',
    String sid = '',
    String alpn = '',
    bool allowInsecure = false,
  }) {
    if (security == 'none' || security.isEmpty) return {};
    final tls = <String, dynamic>{
      'enabled': true,
      if (sni.isNotEmpty) 'server_name': sni,
      if (alpn.isNotEmpty) 'alpn': alpn.split(','),
      if (allowInsecure) 'insecure': true,
      if (fp.isNotEmpty) 'utls': {'enabled': true, 'fingerprint': fp},
    };
    if (security == 'reality') {
      tls['reality'] = {'enabled': true, 'public_key': pbk, 'short_id': sid};
    }
    return {'tls': tls};
  }

  Map<String, dynamic> _transport(
    String type,
    String path,
    String host,
    String serviceName, [
    String mode = '',
    String xPadding = '',
  ]) {
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
          'mode': mode.isEmpty ? 'auto' : mode,
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
      return {
        'type': 'local',
        'tag': tag,
        'format': 'binary',
        'path': localPath,
      };
    }
    const base =
        'https://github.com/runetfreedom/russia-blocked-geoip/raw/release/srs';
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

  String _ipStrategy(IpType t) => switch (t) {
    IpType.ipv4 => 'ipv4_only',
    IpType.ipv6 => 'ipv6_only',
    IpType.both => 'prefer_ipv4',
  };

  Map<String, dynamic> _direct() => {'type': 'direct', 'tag': 'direct'};
  Map<String, dynamic> _block() => {'type': 'block', 'tag': 'block'};

  /// Minimal config for latency testing: no TUN, no inbounds.
  /// sing-box runs as a plain process; Clash API is used to drive the delay test.
  String generateForPing(ParsedProxy proxy, int apiPort) {
    validateTargetCompatibility(proxy);
    if (proxy is AmneziaWGConfig)
      throw UnsupportedError('AWG uses ICMP ping, not sing-box');
    final outbounds = proxy is WireGuardConfig
        ? <Map<String, dynamic>>[]
        : _proxyOutbounds(proxy);
    outbounds.add(_direct());
    return jsonEncode({
      'log': {'level': 'warn'},
      if (proxy is WireGuardConfig) 'endpoints': [_wireguardEndpoint(proxy)],
      'outbounds': outbounds,
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:$apiPort',
          'store_selected': false,
        },
      },
    });
  }

  String generateForAndroid(ParsedProxy proxy, AppSettings settings) {
    validateTargetCompatibility(proxy);
    settings.validateNetworkSettings();
    if (proxy is WireGuardConfig) {
      return _generateForWireGuardEndpoint(_wireguardEndpoint(proxy), settings);
    }
    if (proxy is AmneziaWGConfig) {
      return _generateForWireGuardEndpoint(_amneziaWGEndpoint(proxy), settings);
    }

    final outbounds = _proxyOutbounds(proxy);
    final proxyOut = outbounds.first;
    final supportsSmux =
        proxy is! Hysteria2Config &&
        proxy is! TuicConfig &&
        proxy is! WireGuardConfig &&
        !(proxy is VlessConfig && proxy.flow == 'xtls-rprx-vision');
    if (settings.multiplexerEnabled && supportsSmux) {
      proxyOut['multiplex'] = {
        'enabled': true,
        'protocol': 'smux',
        'max_connections': 4,
        'min_streams': 4,
      };
    }
    outbounds.addAll([_direct(), _block()]);

    final config = {
      'log': _log(settings),
      'dns': _dns(settings.copyWith(enableFakeip: false)),
      'inbounds': _inboundsForAndroid(settings),
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

  String _generateForWireGuardEndpoint(
    Map<String, dynamic> endpoint,
    AppSettings settings,
  ) {
    final config = {
      'log': _log(settings),
      'dns': _dns(settings.copyWith(enableFakeip: false)),
      'inbounds': _inboundsForAndroid(settings),
      'endpoints': [endpoint],
      'outbounds': [_direct(), _block()],
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

  List<Map<String, dynamic>> _inboundsForAndroid(AppSettings s) => [
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

  Map<String, dynamic> _routeForAndroid(AppSettings s) {
    final rules = <Map<String, dynamic>>[
      {'action': 'sniff'},
      if (s.fragmentationEnabled)
        {
          'action': 'route-options',
          'network': 'tcp',
          'protocol': 'tls',
          'tls_fragment': true,
          'tls_fragment_fallback_delay': '500ms',
        },
      {'protocol': 'dns', 'action': 'hijack-dns'},
      // Android "Private DNS: Auto" probes DoT (port 853) on the VPN DNS address
      // (172.19.0.2). Nothing listens there, so the ip_is_private→direct rule would
      // send it to a nonexistent host and time out after 5 seconds on every VPN start.
      // Rejecting immediately makes Android fall back to regular UDP DNS (port 53)
      // without delay.
      {
        'ip_cidr': ['172.19.0.2/32'],
        'port': [853],
        'action': 'reject',
      },
      {'ip_is_private': true, 'outbound': 'direct'},
    ];

    final ruleSets = <Map<String, dynamic>>[];

    if (usesBuiltInGeo(s)) {
      rules.add({'rule_set': 'ru-blocked', 'outbound': 'proxy'});
      rules.add({'rule_set': 'ru-blocked-community', 'outbound': 'proxy'});
      rules.add({'rule_set': 're-filter', 'outbound': 'proxy'});
      // Russian IPv6 → proxy: Android devices commonly lack IPv6 direct connectivity,
      // causing "network is unreachable" errors. Route Russian IPv6 via proxy instead.
      rules.add({'rule_set': 'ru', 'ip_version': 6, 'outbound': 'proxy'});
      rules.add({'rule_set': 'ru', 'outbound': 'direct'});
      ruleSets.addAll([
        _ruleSet('ru-blocked', 'ru-blocked.srs'),
        _ruleSet('ru-blocked-community', 'ru-blocked-community.srs'),
        _ruleSet('re-filter', 're-filter.srs'),
        _ruleSet('ru', 'ru.srs'),
      ]);
    }

    return composeProviderGeoRoute({
      'rules': rules,
      if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
      'final': 'proxy',
      'default_domain_resolver': {
        'server': 'local-dns',
        'strategy': _ipStrategy(s.preferredIpType),
      },
      // Android: no auto_detect_interface — routing handled by VPN service
    }, s, providerRouting,
      guardProviderDirectIpv6: target == SingboxConfigTarget.android);
  }
}
