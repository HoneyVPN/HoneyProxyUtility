import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../domain/entities/vpn_core_status.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../settings/data/models/app_settings.dart';
import '../windows/windows_session.dart';
import '../windows/windows_service_backend.dart';
import '../singbox/geo_data_manager.dart';
import '../singbox/provider_geo_bundle.dart';
import '../../../diagnostics/data/windows_core_diagnostics.dart';

final _log = Logger('WindowsVpnDatasource');

class WindowsVpnDatasource {
  ProviderGeoBundle? _providerRouting;
  void bindProviderRouting(ProviderGeoBundle? bundle) =>
      _providerRouting = bundle;
  Map<String, dynamic> _composeGeo(
    Map<String, dynamic> config,
    AppSettings settings,
    ProviderGeoBundle? bundle,
  ) {
    config['route'] = composeProviderGeoRoute(
      config['route'] as Map<String, dynamic>,
      settings,
      bundle,
    );
    return config;
  }

  WindowsVpnDatasource({
    required this.onStatusChanged,
    this.onError,
    WindowsSessionBackend? sessionBackend,
  }) : _sessions = WindowsSessionController(
         sessionBackend ?? HybridWindowsSessionBackend(),
       );

  final void Function(VpnCoreStatus) onStatusChanged;
  final void Function(String)? onError;
  final WindowsSessionController _sessions;
  final _coreDiagnostics = WindowsCoreDiagnostics();
  StreamSubscription<String>? _statsSub;
  HttpClient? _statsClient;
  Timer? _healthTimer;
  DateTime? _connectedAt;
  int _totalUp = 0;
  int _totalDown = 0;
  int _generation = 0;
  bool _checkingHealth = false;
  static const _clashPort = 9090;

  Future<void> initialize() => _sessions.recover();
  Future<bool> requestPermission() async => true;

  /// Never borrow an orphan core or the selected profile when reopening.
  Future<VpnCoreStatus> readCurrentStatus() async {
    await _sessions.recover();
    return const VpnCoreStatus(state: 'DISCONNECTED');
  }

  Future<bool> checkRunning() async => _sessions.running();
  void reattach() {}

  Future<void> start(
    ParsedProxy proxy, {
    ConnectionMode mode = ConnectionMode.tunnel,
    AppSettings settings = const AppSettings(),
  }) async {
    settings.validateNetworkSettings(
      validateProxyPorts: mode == ConnectionMode.proxy,
    );
    _validateWindowsReserved(proxy);
    await stop();
    final generation = ++_generation;
    final tunnel = mode == ConnectionMode.tunnel;
    onStatusChanged(const VpnCoreStatus(state: 'CONNECTING'));
    String? physicalIface;
    var proxyIps = <String>[];
    if (tunnel) {
      physicalIface = await _detectPhysicalInterface();
      proxyIps = await _resolveHost(proxy.host);
    }
    final support = await getApplicationSupportDirectory();
    // Rule sets are shipped with the app. First connection must not depend on
    // direct GitHub access before the selected VPN can even start.
    final geoPaths = usesBuiltInGeo(settings)
        ? await GeoDataManager.ensureReady()
        : <String, String>{};
    if (generation != _generation) return;
    final cachePath = '${support.path}/honeyvpn_cache.db';
    final config = tunnel
        ? _buildTunConfig(
            proxy,
            settings,
            bindInterface: physicalIface,
            excludeAddresses: proxyIps,
            cachePath: cachePath,
            geoPaths: geoPaths,
          )
        : _buildProxyConfig(
            proxy,
            settings,
            cachePath: cachePath,
            geoPaths: geoPaths,
          );
    final session = await _sessions.start(
      _composeGeo(config, settings, _providerRouting),
      tunnel: tunnel,
      // The supervisor's wire schema includes this field in both modes. TUN
      // has no HTTP listener, so a saved proxy-only port cannot block it.
      httpPort: tunnel ? 2081 : settings.httpPort,
      proxyIp: proxyIps.isEmpty ? null : proxyIps.first.replaceAll('/32', ''),
    );
    if (generation != _generation) {
      await _sessions.stop();
      return;
    }
    _connectedAt = DateTime.now();
    _totalUp = 0;
    _totalDown = 0;
    onStatusChanged(
      const VpnCoreStatus(
        state: 'CONNECTED',
        trafficAvailable: false,
        ratesAvailable: false,
      ),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_checkingHealth) unawaited(_checkHealth(generation));
    });
    unawaited(_startStatsStream(session, generation));
    unawaited(
      _coreDiagnostics.attach(
        session.nonce,
        isCurrent: () =>
            generation == _generation && identical(_sessions.owned, session),
      ),
    );
  }

  Future<void> _checkHealth(int generation) async {
    if (generation != _generation) return;
    _checkingHealth = true;
    try {
      final health = await _sessions.health();
      if (generation != _generation) return;
      if (health == WindowsSessionHealth.unavailable) {
        // A timeout on the statistics/control API is not proof that the owned
        // process exited. Keep the disconnect control and retry next poll.
        _log.warning('Windows VPN status probe unavailable; session retained');
        return;
      }
      if (health == WindowsSessionHealth.stopped) {
        await _cancelStats();
        if (generation != _generation) return;
        await _sessions.stop();
        if (generation != _generation) return;
        _connectedAt = null;
        onError?.call(
          const WindowsSessionException(
            WindowsSessionFailure.connectionLost,
          ).code,
        );
      }
    } catch (_) {
      if (generation == _generation) {
        await _cancelStats();
        if (generation != _generation) return;
        _connectedAt = null;
        onError?.call(
          const WindowsSessionException(
            WindowsSessionFailure.recoveryRequired,
          ).code,
        );
      }
    } finally {
      _checkingHealth = false;
    }
  }

  Future<void> _startStatsStream(WindowsSession session, int generation) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';
    _statsClient = client;
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$_clashPort/traffic'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${session.nonce}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (generation != _generation || response.statusCode != 200) {
        client.close(force: true);
        return;
      }
      _statsSub = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              final connectedAt = _connectedAt;
              if (generation != _generation ||
                  connectedAt == null ||
                  line.length > 16384)
                return;
              try {
                final data = jsonDecode(line) as Map<String, dynamic>;
                final up = data['up'];
                final down = data['down'];
                if (up is! num ||
                    down is! num ||
                    !up.isFinite ||
                    !down.isFinite ||
                    up < 0 ||
                    down < 0)
                  return;
                _totalUp += up.toInt();
                _totalDown += down.toInt();
                onStatusChanged(
                  VpnCoreStatus(
                    state: 'CONNECTED',
                    uploadSpeed: up.toInt(),
                    downloadSpeed: down.toInt(),
                    upload: _totalUp,
                    download: _totalDown,
                    duration: _duration(DateTime.now().difference(connectedAt)),
                  ),
                );
              } catch (_) {
                /* Invalid traffic data cannot establish a connection. */
              }
            },
            onError: (Object _) {
              _markStatsUnavailable(generation);
              client.close(force: true);
            },
            onDone: () => _markStatsUnavailable(generation),
          );
    } catch (_) {
      _markStatsUnavailable(generation);
      client.close(force: true);
    }
  }

  void _markStatsUnavailable(int generation) {
    final connectedAt = _connectedAt;
    if (generation != _generation || connectedAt == null) return;
    onStatusChanged(
      VpnCoreStatus(
        state: 'CONNECTED',
        trafficAvailable: false,
        ratesAvailable: false,
        duration: _duration(DateTime.now().difference(connectedAt)),
      ),
    );
  }

  static String _duration(Duration elapsed) =>
      '${elapsed.inHours.toString().padLeft(2, '0')}:'
      '${(elapsed.inMinutes % 60).toString().padLeft(2, '0')}:'
      '${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

  Future<void> _cancelStats() async {
    _healthTimer?.cancel();
    _healthTimer = null;
    _statsClient?.close(force: true);
    _statsClient = null;
    await _coreDiagnostics.stop();
    await _statsSub?.cancel();
    _statsSub = null;
  }

  Future<void> stop() async {
    _generation++;
    await _cancelStats();
    await _sessions.stop();
    _connectedAt = null;
    onStatusChanged(const VpnCoreStatus(state: 'DISCONNECTED'));
  }

  Future<int> ping(ParsedProxy proxy) async {
    Socket? socket;
    try {
      final watch = Stopwatch()..start();
      socket = await Socket.connect(
        proxy.host,
        proxy.port,
        timeout: const Duration(seconds: 5),
      );
      return watch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      await socket?.close();
    }
  }

  void dispose() {
    _generation++;
    unawaited(_cancelStats());
    // The supervisor's finally block owns child/routes/proxy cleanup.
    unawaited(
      _sessions.stop().catchError((Object _) {
        _log.warning('Windows VPN cleanup was not confirmed during disposal');
      }),
    );
  }

  // ── Config builders ───────────────────────────────────────────────────────────

  /// Builds the exact configuration used for a session, without starting processes.
  @visibleForTesting
  Map<String, dynamic> buildConfiguration(
    ParsedProxy proxy,
    AppSettings settings, {
    ConnectionMode mode = ConnectionMode.tunnel,
    String? bindInterface,
    List<String> excludeAddresses = const [],
    Map<String, String>? geoPaths,
    ProviderGeoBundle? providerRouting,
  }) {
    _validateWindowsReserved(proxy);
    final config = mode == ConnectionMode.tunnel
        ? _buildTunConfig(
            proxy,
            settings,
            bindInterface: bindInterface,
            excludeAddresses: excludeAddresses,
            geoPaths: geoPaths,
          )
        : _buildProxyConfig(proxy, settings, geoPaths: geoPaths);
    return _composeGeo(config, settings, providerRouting ?? _providerRouting);
  }

  static void _validateWindowsReserved(ParsedProxy proxy) {
    final reserved = switch (proxy) {
      WireGuardConfig c => c.reserved,
      AmneziaWGConfig c => c.reserved,
      _ => null,
    };
    if (reserved != null &&
        reserved.isNotEmpty &&
        (reserved.length != 3 || reserved.any((byte) => byte != 0))) {
      // The newer Windows core removed the outgoing packet-byte rewrite.
      // Keep the stored profile intact for cores which still support it.
      throw UnsupportedError(
        'WireGuard reserved bytes are unsupported by this Windows core.',
      );
    }
  }

  Map<String, dynamic> _buildProxyConfig(
    ParsedProxy proxy,
    AppSettings s, {
    String? cachePath,
    Map<String, String>? geoPaths,
  }) {
    s.validateNetworkSettings();
    final listen = s.allowLanConnections ? '0.0.0.0' : '127.0.0.1';

    final routeRules = <Map<String, dynamic>>[
      {'action': 'sniff'},
      if (s.fragmentationEnabled)
        {
          'action': 'route-options',
          'tls_fragment': true,
          'tls_fragment_fallback_delay': '500ms',
        },
      {'ip_is_private': true, 'outbound': 'direct'},
    ];
    final ruleSets = <Map<String, dynamic>>[];

    if (usesBuiltInGeo(s)) {
      routeRules.addAll([
        {'rule_set': 'ru-blocked', 'outbound': 'proxy'},
        {'rule_set': 'ru-blocked-community', 'outbound': 'proxy'},
        {'rule_set': 're-filter', 'outbound': 'proxy'},
        {'rule_set': 'ru', 'ip_version': 4, 'outbound': 'direct'},
      ]);
      ruleSets.addAll([
        _ruleSet('ru-blocked', 'ru-blocked.srs', geoPaths),
        _ruleSet('ru-blocked-community', 'ru-blocked-community.srs', geoPaths),
        _ruleSet('re-filter', 're-filter.srs', geoPaths),
        _ruleSet('ru', 'ru.srs', geoPaths),
      ]);
    }

    final experimental = <String, dynamic>{
      'clash_api': {'external_controller': '127.0.0.1:$_clashPort'},
      if (cachePath != null) 'cache_file': {'enabled': true, 'path': cachePath},
    };

    if (proxy is AmneziaWGConfig || proxy is WireGuardConfig) {
      return {
        'log': {'level': s.logLevel.name},
        'dns': _dns(s),
        'experimental': experimental,
        'inbounds': [
          {
            'type': 'socks',
            'tag': 'socks-in',
            'listen': listen,
            'listen_port': s.socksPort,
          },
          {
            'type': 'http',
            'tag': 'http-in',
            'listen': listen,
            'listen_port': s.httpPort,
          },
        ],
        'endpoints': [_buildEndpoint(proxy, s)],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
          {'type': 'block', 'tag': 'block'},
        ],
        'route': {
          'rules': routeRules,
          if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
          'final': 'proxy',
          'default_domain_resolver': _domainResolver(s),
          'auto_detect_interface': true,
        },
      };
    }

    return {
      'log': {'level': s.logLevel.name},
      'dns': _dns(s),
      'experimental': experimental,
      'inbounds': [
        {
          'type': 'socks',
          'tag': 'socks-in',
          'listen': listen,
          'listen_port': s.socksPort,
        },
        {
          'type': 'http',
          'tag': 'http-in',
          'listen': listen,
          'listen_port': s.httpPort,
        },
      ],
      'outbounds': [
        _configuredOutbound(proxy, s),
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'},
      ],
      'route': {
        'rules': routeRules,
        if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
        'final': 'proxy',
        'default_domain_resolver': _domainResolver(s),
        'auto_detect_interface': true,
      },
    };
  }

  static Future<String?> _detectPhysicalInterface() async {
    try {
      final r = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        // Match the supervisor's explicit IPv4 gateway selector, including
        // deterministic ties. Route objects need no adapted InterfaceMetric.
        r"$ErrorActionPreference='Stop'; $metrics=@{}; "
            r'foreach($i in @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop)) {'
            r'$metrics[[int]$i.InterfaceIndex]=[long]$i.InterfaceMetric}; '
            r'Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | '
            r"Where-Object {$_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0'} | "
            r'Sort-Object @{Expression={if(-not $metrics.ContainsKey([int]$_.InterfaceIndex)){throw "missing-interface-metric"}; '
            r'[long]$_.RouteMetric+$metrics[[int]$_.InterfaceIndex]}}, InterfaceIndex, NextHop | '
            r'Select-Object -First 1 -ExpandProperty InterfaceAlias',
      ]).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return null;
      final name = r.stdout.toString().trim();
      return name.isNotEmpty ? name : null;
    } catch (_) {
      return null;
    }
  }

  static Future<List<String>> _resolveHost(String host) async {
    final isIp = RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host);
    if (isIp) return ['$host/32'];
    try {
      final addrs = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 5));
      return addrs
          .where((a) => a.type == InternetAddressType.IPv4)
          .map((a) => '${a.address}/32')
          .toList();
    } catch (_) {
      return [];
    }
  }

  Map<String, dynamic> _buildTunConfig(
    ParsedProxy proxy,
    AppSettings s, {
    String? bindInterface,
    List<String> excludeAddresses = const [],
    String? cachePath,
    Map<String, String>? geoPaths,
  }) {
    s.validateNetworkSettings(validateProxyPorts: false);
    final tunInbound = <String, dynamic>{
      'type': 'tun',
      'tag': 'tun-in',
      // DNS preference does not determine which packets Windows routes into
      // the VPN. Capture both address families, including literal IPv6 URLs.
      'address': ['198.18.0.1/16', 'fdfe:dcba:9876::1/126'],
      'auto_route': true,
      'strict_route': false,
      'stack': s.tunStack.name,
      if (excludeAddresses.isNotEmpty)
        'route_exclude_address': excludeAddresses,
    };
    final routeRules = <Map<String, dynamic>>[
      {'action': 'sniff'},
      if (s.fragmentationEnabled)
        {
          'action': 'route-options',
          'tls_fragment': true,
          'tls_fragment_fallback_delay': '500ms',
        },
      {'protocol': 'dns', 'action': 'hijack-dns'},
      {'ip_is_private': true, 'outbound': 'direct'},
    ];
    final ruleSets = <Map<String, dynamic>>[];
    if (usesBuiltInGeo(s)) {
      routeRules.addAll([
        {'rule_set': 'ru-blocked', 'outbound': 'proxy'},
        {'rule_set': 'ru-blocked-community', 'outbound': 'proxy'},
        {'rule_set': 're-filter', 'outbound': 'proxy'},
        {'rule_set': 'ru', 'ip_version': 4, 'outbound': 'direct'},
      ]);
      ruleSets.addAll([
        _ruleSet('ru-blocked', 'ru-blocked.srs', geoPaths),
        _ruleSet('ru-blocked-community', 'ru-blocked-community.srs', geoPaths),
        _ruleSet('re-filter', 're-filter.srs', geoPaths),
        _ruleSet('ru', 'ru.srs', geoPaths),
      ]);
    }

    final tunExperimental = <String, dynamic>{
      'clash_api': {'external_controller': '127.0.0.1:$_clashPort'},
      if (cachePath != null) 'cache_file': {'enabled': true, 'path': cachePath},
    };

    if (proxy is AmneziaWGConfig || proxy is WireGuardConfig) {
      final endpoint = _buildEndpoint(proxy, s);
      if (bindInterface != null) endpoint['bind_interface'] = bindInterface;
      return {
        'log': {'level': s.logLevel.name},
        'dns': _dns(s),
        'experimental': tunExperimental,
        'inbounds': [tunInbound],
        'endpoints': [endpoint],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'rules': routeRules,
          if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
          'final': 'proxy',
          'default_domain_resolver': _domainResolver(s),
          'auto_detect_interface': true,
        },
      };
    }

    final proxyOutbound = _configuredOutbound(proxy, s);
    if (bindInterface != null) proxyOutbound['bind_interface'] = bindInterface;

    return {
      'log': {'level': s.logLevel.name},
      'dns': _dns(s),
      'experimental': tunExperimental,
      'inbounds': [tunInbound],
      'outbounds': [
        proxyOutbound,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': routeRules,
        if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
        'final': 'proxy',
        'default_domain_resolver': _domainResolver(s),
        'auto_detect_interface': true,
      },
    };
  }

  Map<String, dynamic> _dns(AppSettings s) => {
    'servers': [
      {
        'tag': 'remote',
        ..._typedRemoteDns(s),
        'domain_resolver': _domainResolver(s),
        'detour': 'proxy',
      },
      {'tag': 'local', 'type': 'local', 'detour': 'direct'},
    ],
    'rules': <Map<String, dynamic>>[],
    'final': 'remote',
    'strategy': _ipStrategy(s),
  };

  static String _ipStrategy(AppSettings s) => switch (s.preferredIpType) {
    IpType.ipv4 => 'ipv4_only',
    IpType.ipv6 => 'ipv6_only',
    IpType.both => 'prefer_ipv4',
  };

  static Map<String, dynamic> _domainResolver(AppSettings s) => {
    'server': 'local',
    'strategy': _ipStrategy(s),
  };

  static Map<String, dynamic> _typedRemoteDns(AppSettings s) {
    final uri = Uri.parse(_remoteDns(s).trim());
    return {
      'type': uri.scheme,
      'server': uri.host,
      if (uri.hasPort) 'server_port': uri.port,
      if (uri.scheme == 'https')
        'path': uri.path.isEmpty ? '/dns-query' : uri.path,
    };
  }

  Map<String, dynamic> _configuredOutbound(ParsedProxy proxy, AppSettings s) {
    final outbound = _buildOutbound(proxy);
    if (s.multiplexerEnabled &&
        !(proxy is VlessConfig && proxy.flow == 'xtls-rprx-vision') &&
        proxy is! Hysteria2Config &&
        proxy is! TuicConfig &&
        proxy is! WireGuardConfig) {
      outbound['multiplex'] = {
        'enabled': true,
        'protocol': 'smux',
        'max_connections': 4,
        'min_streams': 4,
      };
    }
    return outbound;
  }

  static String _remoteDns(AppSettings s) => switch (s.dnsPreset) {
    DnsPreset.cloudflare => 'https://1.1.1.1/dns-query',
    DnsPreset.google => 'https://8.8.8.8/dns-query',
    DnsPreset.adguard => 'https://94.140.14.14/dns-query',
    DnsPreset.custom =>
      s.customDnsUrl.isNotEmpty ? s.customDnsUrl : 'https://1.1.1.1/dns-query',
  };

  static Map<String, dynamic> _ruleSet(
    String tag,
    String filename,
    Map<String, String>? geoPaths,
  ) {
    final path = geoPaths?[filename];
    if (path != null) {
      return {'type': 'local', 'tag': tag, 'format': 'binary', 'path': path};
    }
    if (geoPaths != null) {
      throw StateError('Bundled routing data is missing');
    }
    // Configuration-only callers can omit assets. Runtime always supplies the
    // complete packaged map, so this fallback is never a startup download.
    return _remoteRuleSet(tag, filename);
  }

  static Map<String, dynamic> _remoteRuleSet(String tag, String filename) {
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

  Map<String, dynamic> _buildEndpoint(ParsedProxy proxy, AppSettings s) =>
      switch (proxy) {
        WireGuardConfig c => {
          'type': 'wireguard',
          'tag': 'proxy',
          'system': false,
          'domain_resolver': _domainResolver(s),
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
            },
          ],
        },
        AmneziaWGConfig c => _buildAwgEndpoint(c, s),
        _ => throw ArgumentError('Expected a WireGuard endpoint'),
      };

  Map<String, dynamic> _buildAwgEndpoint(AmneziaWGConfig c, AppSettings s) {
    final peer = <String, dynamic>{
      'address': c.host,
      'port': c.port,
      'public_key': c.publicKey,
      'allowed_ips': ['0.0.0.0/0', '::/0'],
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
      'domain_resolver': _domainResolver(s),
      'address': c.addresses.isNotEmpty ? c.addresses : ['10.0.0.1/32'],
      'private_key': c.privateKey,
      'listen_port': 0,
      'peers': [peer],
      'mtu': c.mtu,
      'amnezia': amnezia,
    };
  }

  Map<String, dynamic> _buildOutbound(ParsedProxy proxy) => switch (proxy) {
    VlessConfig c => _vlessOutbound(c),
    VmessConfig c => {
      'type': 'vmess',
      'tag': 'proxy',
      'server': c.host,
      'server_port': c.port,
      'uuid': c.uuid,
      'alter_id': c.alterId,
      'security': c.security.isEmpty ? 'auto' : c.security,
      if (c.tls == 'tls') 'tls': {'enabled': true, 'server_name': c.sni},
      if (_hasTransport(c.network))
        'transport': _transport(c.network, c.path, c.wsHost, ''),
    },
    TrojanConfig c => {
      'type': 'trojan',
      'tag': 'proxy',
      'server': c.host,
      'server_port': c.port,
      'password': c.password,
      'tls': {
        'enabled': true,
        'server_name': c.sni,
        if (c.alpn.isNotEmpty) 'alpn': c.alpn.split(','),
      },
      if (_hasTransport(c.transport))
        'transport': _transport(c.transport, c.path, c.transportHost, ''),
    },
    ShadowsocksConfig c => {
      'type': 'shadowsocks',
      'tag': 'proxy',
      'server': c.host,
      'server_port': c.port,
      'method': c.method,
      'password': c.password,
    },
    Hysteria2Config c => _hysteria2Outbound(c),
    TuicConfig c => {
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
    },
    _ => throw UnsupportedError(
      '${proxy.protocolLabel} not yet supported on Windows',
    ),
  };

  Map<String, dynamic> _vlessOutbound(VlessConfig c) {
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
      if (c.security.isNotEmpty && c.security != 'none') 'tls': _vlessTls(c),
      if (_hasTransport(c.transport))
        'transport': _transport(
          c.transport,
          c.path,
          c.transportHost,
          c.grpcServiceName,
          c.xhttpMode,
          c.xPaddingBytes,
        ),
    };
  }

  Map<String, dynamic> _hysteria2Outbound(Hysteria2Config c) {
    c.validateCoreCompatibility();
    return {
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': c.host,
      'server_port': c.port,
      'password': c.auth,
      if (c.serverPorts.isNotEmpty) 'server_ports': c.serverPorts,
      if (c.hopInterval.isNotEmpty) 'hop_interval': c.hopInterval,
      'tls': {
        'enabled': true,
        if (c.sni.isNotEmpty) 'server_name': c.sni,
        if (c.insecure) 'insecure': true,
      },
      if (c.obfs.isNotEmpty)
        'obfs': {'type': c.obfs, 'password': c.obfsPassword},
    };
  }

  Map<String, dynamic> _vlessTls(VlessConfig c) {
    final tls = <String, dynamic>{'enabled': true};
    if (c.sni.isNotEmpty) tls['server_name'] = c.sni;
    if (c.effectiveAlpn.isNotEmpty) tls['alpn'] = c.effectiveAlpn;
    if (c.allowInsecure) tls['insecure'] = true;
    if (c.effectiveFingerprint.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': c.effectiveFingerprint};
    }
    if (c.security == 'reality') {
      tls['reality'] = {
        'enabled': true,
        'public_key': c.publicKey,
        'short_id': c.shortId,
      };
    }
    return tls;
  }

  bool _hasTransport(String t) => t.isNotEmpty && t != 'tcp';

  Map<String, dynamic> _transport(
    String type,
    String path,
    String host,
    String grpcService, [
    String mode = '',
    String xPadding = '',
  ]) => switch (type) {
    'ws' => {
      'type': 'ws',
      'path': path.isEmpty ? '/' : path,
      if (host.isNotEmpty) 'headers': {'Host': host},
    },
    'h2' || 'http' => {
      'type': 'http',
      'path': path.isEmpty ? '/' : path,
      if (host.isNotEmpty) 'host': [host],
    },
    'grpc' => {'type': 'grpc', 'service_name': grpcService},
    'httpupgrade' => {
      'type': 'httpupgrade',
      'path': path.isEmpty ? '/' : path,
      if (host.isNotEmpty) 'host': host,
    },
    'xhttp' => {
      'type': 'xhttp',
      'path': path.isEmpty ? '/' : path,
      if (host.isNotEmpty) 'host': host,
      'mode': mode.isEmpty ? 'auto' : mode,
      'x_padding_bytes': xPadding.isNotEmpty ? xPadding : '100-1000',
    },
    _ => {'type': type},
  };
}
