import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../settings/data/models/app_settings.dart';

final _log = Logger('WindowsVpnDatasource');

class WindowsVpnDatasource {
  final void Function(V2RayStatus) onStatusChanged;
  Process? _sbProcess;
  StreamSubscription<String>? _statsSub;
  Timer? _fallbackTimer;
  DateTime? _connectedAt;
  int _totalUp   = 0;
  int _totalDown = 0;
  bool _tunMode  = false;
  String? _tunStopFilePath;

  static const _socksPort = 10808;
  static const _httpPort  = 10809;
  static const _clashPort = 9090;

  WindowsVpnDatasource({required this.onStatusChanged});

  Future<void> initialize() async {}
  Future<bool> requestPermission() async => true;

  Future<void> start(
    ParsedProxy proxy, {
    ConnectionMode mode = ConnectionMode.tunnel,
    AppSettings settings = const AppSettings(),
  }) async {
    await stop();
    _tunMode = mode == ConnectionMode.tunnel;

    final exeDir = File(Platform.resolvedExecutable).parent;
    final sbExe  = File('${exeDir.path}/sing-box.exe');
    if (!sbExe.existsSync()) {
      throw Exception('sing-box.exe not found at ${sbExe.path}');
    }

    onStatusChanged(V2RayStatus(state: 'CONNECTING'));

    if (_tunMode) {
      await _startTunElevated(proxy, sbExe, settings);
    } else {
      await _startProxy(proxy, sbExe, settings);
    }
  }

  // ── TUN mode ─────────────────────────────────────────────────────────────────

  Future<void> _startTunElevated(ParsedProxy proxy, File sbExe, AppSettings settings) async {
    final tmp      = await getTemporaryDirectory();
    final cfgFile  = File('${tmp.path}/honeyvpn_sb.json');
    final psFile   = File('${tmp.path}/honeyvpn_tun.ps1');
    final stopFile = File('${tmp.path}/honeyvpn_tun_stop');
    final logFile  = File('${tmp.path}/honeyvpn_sb.log');
    _tunStopFilePath = stopFile.path;

    // Detect physical interface before TUN hijacks all routes.
    // This name is injected into the proxy outbound as bind_interface so
    // sing-box sends traffic to the VPN server via the real NIC, not TUN.
    final physicalIface = await _detectPhysicalInterface();

    // Resolve proxy hostname to IP before TUN starts.
    final proxyIps = await _resolveHost(proxy.host);
    // Raw IP without CIDR for OS route command.
    final proxyIp  = proxyIps.isNotEmpty ? proxyIps.first.replaceAll('/32', '') : null;

    await cfgFile.writeAsString(jsonEncode(_buildTunConfig(proxy, bindInterface: physicalIface, excludeAddresses: proxyIps)));
    if (stopFile.existsSync()) stopFile.deleteSync();

    final sbPath   = sbExe.path.replaceAll("'", "''");
    final cfgPath  = cfgFile.path.replaceAll("'", "''");
    final stopPath = stopFile.path.replaceAll("'", "''");
    final logPath  = logFile.path.replaceAll("'", "''");

    // Build PowerShell script.
    // IMPORTANT: before starting sing-box we add an OS-level static route for the
    // proxy server IP via the physical default gateway. This guarantees that
    // sing-box's own outbound connection to the VPN server never enters the TUN
    // interface, preventing the routing loop — regardless of sing-box version.
    final psLines = <String>[
      r"$env:ENABLE_DEPRECATED_LEGACY_DNS_SERVERS = 'true'",
      r"$env:ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER = 'true'",
      r"$env:ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM = 'true'",
      "Remove-Item -Path '$stopPath' -ErrorAction SilentlyContinue",
      "Remove-Item -Path '$logPath' -ErrorAction SilentlyContinue",
      // Find physical default gateway (before TUN routes are installed).
      r"$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | " +
          r"Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1).NextHop",
      if (proxyIp != null)
        r"if ($gw) { route add " + proxyIp + r" mask 255.255.255.255 $gw metric 1 2>&1 | Out-Null }",
      r"$proc = Start-Process -FilePath '" + sbPath +
          r"' -ArgumentList @('run', '-c', '" + cfgPath +
          r"') -NoNewWindow -PassThru -RedirectStandardError '" + logPath + r"'",
      r"while (-not $proc.HasExited -and -not (Test-Path '" + stopPath + r"')) {",
      r"    Start-Sleep -Milliseconds 300",
      r"}",
      r"if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }",
      if (proxyIp != null)
        r"route delete " + proxyIp + r" mask 255.255.255.255 2>&1 | Out-Null",
      "Remove-Item -Path '$stopPath' -ErrorAction SilentlyContinue",
    ];

    await psFile.writeAsString(psLines.join("\r\n"));

    // Embed actual path via Dart interpolation.
    // Use array-style ArgumentList so paths with spaces work correctly.
    final psPathPs = psFile.path.replaceAll("'", "''");
    await Process.run('powershell', [
      '-NoProfile', '-NonInteractive', '-Command',
      "Start-Process powershell -Verb RunAs -WindowStyle Hidden "
          "-ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','$psPathPs')",
    ]);

    _connectedAt = DateTime.now();
    _totalUp = 0;
    _totalDown = 0;

    // Poll Clash API until sing-box is ready (UAC + PowerShell startup can take 10+ s).
    bool started = false;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!started && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 800));
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      try {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$_clashPort/'));
        await req.close();
        started = true;
      } catch (_) {
      } finally {
        client.close();
      }
    }

    if (!started) {
      _tunStopFilePath = null;
      _connectedAt = null;
      String sbDetail = '';
      try {
        final log = logFile.readAsStringSync().trim();
        if (log.isNotEmpty) {
          sbDetail = log.split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();
        }
      } catch (_) {}
      throw Exception(
        'TUN режим не запустился.\nВозможные причины:\n'
        '• Запрос администратора был отклонён\n'
        '• sing-box завершился с ошибкой'
        '${sbDetail.isNotEmpty ? "\n\n$sbDetail" : ""}',
      );
    }

    onStatusChanged(V2RayStatus(state: 'CONNECTED'));
    unawaited(_startStatsStream());
  }

  // ── Proxy mode ────────────────────────────────────────────────────────────────

  Future<void> _startProxy(ParsedProxy proxy, File sbExe, AppSettings settings) async {
    final tmp     = await getTemporaryDirectory();
    final cfgFile = File('${tmp.path}/honeyvpn_sb.json');
    await cfgFile.writeAsString(jsonEncode(_buildProxyConfig(proxy, settings)));

    final stderrBuf = StringBuffer();
    final proc = await Process.start(
      sbExe.path, ['run', '-c', cfgFile.path],
      environment: {
        ...Platform.environment,
        'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
        'ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM': 'true',
        'ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER': 'true',
      },
    );
    _sbProcess   = proc;
    _connectedAt = DateTime.now();
    _totalUp     = 0;
    _totalDown   = 0;

    proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((s) => stderrBuf.write(s));
    proc.exitCode.then((code) {
      if (_sbProcess == proc) {
        _sbProcess = null;
        onStatusChanged(V2RayStatus(state: 'DISCONNECTED'));
      }
    });

    await Future.delayed(const Duration(milliseconds: 2000));

    if (_sbProcess == null) {
      final err      = stderrBuf.toString().trim();
      final lastLine = err.isNotEmpty ? err.split('\n').last : 'unknown error';
      throw Exception('sing-box exited unexpectedly: $lastLine');
    }

    await _setSystemProxy('127.0.0.1', settings.httpPort);
    onStatusChanged(V2RayStatus(state: 'CONNECTED'));
    unawaited(_startStatsStream());
  }

  // ── Stats stream ──────────────────────────────────────────────────────────────

  Future<void> _startStatsStream() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req  = await client.getUrl(Uri.parse('http://127.0.0.1:$_clashPort/traffic'));
      final resp = await req.close();

      _statsSub = resp
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.trim().isEmpty) return;
          final connectedAt = _connectedAt;
          if (connectedAt == null) return;
          try {
            final data = json.decode(line) as Map<String, dynamic>;
            final up   = (data['up']   as num? ?? 0).toInt();
            final down = (data['down'] as num? ?? 0).toInt();
            _totalUp   += up;
            _totalDown += down;

            final elapsed = DateTime.now().difference(connectedAt);
            final h = elapsed.inHours.toString().padLeft(2, '0');
            final m = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
            final s = (elapsed.inSeconds % 60).toString().padLeft(2, '0');

            onStatusChanged(V2RayStatus(
              state:         'CONNECTED',
              uploadSpeed:   up,
              downloadSpeed: down,
              upload:        _totalUp,
              download:      _totalDown,
              duration:      '$h:$m:$s',
            ));
          } catch (e) {
            _log.fine('Stats parse error: $e');
          }
        },
        onError: (e) {
          _log.warning('Stats stream error', e);
          _startFallbackTimer();
        },
      );
    } catch (e) {
      _log.warning('Cannot connect to Clash stats API', e);
      _startFallbackTimer();
    } finally {
      client.close();
    }
  }

  void _startFallbackTimer() {
    if (_fallbackTimer != null) return;
    _fallbackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final connectedAt = _connectedAt;
      if (connectedAt == null) return;
      final elapsed = DateTime.now().difference(connectedAt);
      final h = elapsed.inHours.toString().padLeft(2, '0');
      final m = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
      final s = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
      onStatusChanged(V2RayStatus(state: 'CONNECTED', duration: '$h:$m:$s'));
    });
  }

  // ── Stop ──────────────────────────────────────────────────────────────────────

  Future<void> stop() async {
    await _statsSub?.cancel();
    _statsSub = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _connectedAt  = null;

    if (_sbProcess != null) {
      _sbProcess!.kill();
      _sbProcess = null;
    } else {
      _signalTunStop();
    }
    _tunMode         = false;
    _tunStopFilePath = null;

    try {
      await _clearSystemProxy();
    } catch (e) {
      _log.warning('Failed to clear system proxy', e);
    }
    onStatusChanged(V2RayStatus(state: 'DISCONNECTED'));
  }

  void _signalTunStop() {
    final path = _tunStopFilePath;
    if (path == null) return;
    try {
      File(path).writeAsStringSync('stop');
    } catch (e) {
      _log.warning('Failed to write TUN stop signal', e);
    }
  }

  Future<int> ping(ParsedProxy proxy) async {
    Socket? sock;
    try {
      final sw = Stopwatch()..start();
      sock = await Socket.connect(proxy.host, proxy.port,
          timeout: const Duration(seconds: 5));
      sw.stop();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      await sock?.close();
    }
  }

  void dispose() {
    _statsSub?.cancel();
    _statsSub = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _connectedAt = null;
    _sbProcess?.kill();
    _sbProcess = null;
    _signalTunStop();
    _clearSystemProxy().catchError((e) {
      _log.warning('dispose: clear system proxy failed', e);
    });
  }

  // ── System proxy ──────────────────────────────────────────────────────────────

  Future<void> _setSystemProxy(String host, int port) async {
    const k = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    await Process.run('reg', ['add', k, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']);
    await Process.run('reg', ['add', k, '/v', 'ProxyServer',  '/t', 'REG_SZ',    '/d', '$host:$port', '/f']);
  }

  Future<void> _clearSystemProxy() async {
    const k = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    await Process.run('reg', ['add', k, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
  }

  // ── Config builders ───────────────────────────────────────────────────────────

  Map<String, dynamic> _buildProxyConfig(ParsedProxy proxy, AppSettings s) {
    final listen = s.allowLanConnections ? '0.0.0.0' : '127.0.0.1';

    final routeRules = <Map<String, dynamic>>[
      {'action': 'sniff'},
      if (s.fragmentationEnabled) {'action': 'tls_fragment'},
      {'ip_is_private': true, 'outbound': 'direct'},
    ];
    final ruleSets = <Map<String, dynamic>>[];

    if (s.routingMode == RoutingMode.bypassRU || s.routingMode == RoutingMode.rules) {
      routeRules.addAll([
        {'rule_set': 'ru-blocked',           'outbound': 'proxy'},
        {'rule_set': 'ru-blocked-community', 'outbound': 'proxy'},
        {'rule_set': 're-filter',            'outbound': 'proxy'},
        {'rule_set': 'ru',                   'outbound': 'direct'},
      ]);
      ruleSets.addAll([
        _remoteRuleSet('ru-blocked',           'ru-blocked.srs'),
        _remoteRuleSet('ru-blocked-community', 'ru-blocked-community.srs'),
        _remoteRuleSet('re-filter',            're-filter.srs'),
        _remoteRuleSet('ru',                   'ru.srs'),
      ]);
    }
    if (s.blockAds) {
      routeRules.add({'rule_set': 'geosite-category-ads-all', 'outbound': 'block'});
      ruleSets.add(_remoteRuleSet('geosite-category-ads-all', 'geosite-category-ads-all.srs'));
    }

    return {
      'log': {'level': s.logLevel.name},
      'experimental': {
        'clash_api': {'external_controller': '127.0.0.1:$_clashPort'},
      },
      'inbounds': [
        {'type': 'socks', 'tag': 'socks-in', 'listen': listen, 'listen_port': s.socksPort},
        {'type': 'http',  'tag': 'http-in',  'listen': listen, 'listen_port': s.httpPort},
      ],
      'outbounds': [
        _buildOutbound(proxy),
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block',  'tag': 'block'},
      ],
      'route': {
        'rules': routeRules,
        if (ruleSets.isNotEmpty) 'rule_set': ruleSets,
        'final': 'proxy',
        'auto_detect_interface': true,
      },
    };
  }

  static Future<String?> _detectPhysicalInterface() async {
    try {
      final r = await Process.run('powershell', [
        '-NoProfile', '-NonInteractive', '-Command',
        r"(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | "
        r"Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1).InterfaceAlias",
      ]);
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
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 5));
      return addrs
          .where((a) => a.type == InternetAddressType.IPv4)
          .map((a) => '${a.address}/32')
          .toList();
    } catch (_) {
      return [];
    }
  }

  Map<String, dynamic> _buildTunConfig(
    ParsedProxy proxy, {
    String? bindInterface,
    List<String> excludeAddresses = const [],
  }) {
    final proxyOutbound = _buildOutbound(proxy);
    // Bind proxy outbound to physical NIC — backup routing loop prevention.
    if (bindInterface != null) proxyOutbound['bind_interface'] = bindInterface;

    return {
      'log': {'level': 'warn'},
      'dns': {
        'servers': [
          {'tag': 'remote', 'address': 'udp://8.8.8.8', 'detour': 'proxy'},
          {'tag': 'local',  'address': 'local',          'detour': 'direct'},
        ],
        'rules': [
          {'outbound': 'any', 'server': 'local'},
        ],
        'final': 'remote',
      },
      'experimental': {
        'clash_api': {'external_controller': '127.0.0.1:$_clashPort'},
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': ['198.18.0.1/16'],
          'auto_route': true,
          'strict_route': false,
          'stack': 'mixed',
          // Exclude proxy server IPs so sing-box never routes its own
          // connections to the proxy through TUN (primary routing loop fix).
          if (excludeAddresses.isNotEmpty)
            'route_exclude_address': excludeAddresses,
        },
      ],
      'outbounds': [
        proxyOutbound,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {'action': 'sniff'},
          {'protocol': 'dns', 'action': 'hijack-dns'},
          {'ip_is_private': true, 'outbound': 'direct'},
        ],
        'final': 'proxy',
        'auto_detect_interface': true,
      },
    };
  }

  static String _remoteDns(AppSettings s) => switch (s.dnsPreset) {
    DnsPreset.cloudflare => 'tls://1.1.1.1',
    DnsPreset.google     => 'tls://8.8.8.8',
    DnsPreset.adguard    => 'tls://94.140.14.14',
    DnsPreset.custom     => s.customDnsUrl.isNotEmpty ? s.customDnsUrl : 'tls://1.1.1.1',
  };

  static Map<String, dynamic> _remoteRuleSet(String tag, String filename) {
    const base   = 'https://github.com/runetfreedom/russia-blocked-geoip/raw/release/srs';
    const adBase = 'https://github.com/SagerNet/sing-geosite/raw/rule-set';
    final url = filename == 'geosite-category-ads-all.srs' ? '$adBase/$filename' : '$base/$filename';
    return {'type': 'remote', 'tag': tag, 'format': 'binary', 'url': url, 'download_detour': 'direct', 'update_interval': '7d'};
  }

  Map<String, dynamic> _buildOutbound(ParsedProxy proxy) => switch (proxy) {
    VlessConfig c => {
      'type': 'vless',
      'tag': 'proxy',
      'server': c.host,
      'server_port': c.port,
      'uuid': c.uuid,
      if (c.flow.isNotEmpty) 'flow': c.flow,
      'tls': _vlessTls(c),
      if (_hasTransport(c.transport))
        'transport': _transport(c.transport, c.path, c.transportHost, c.grpcServiceName, c.xhttpMode, c.xPaddingBytes),
    },
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
    Hysteria2Config c => {
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': c.host,
      'server_port': c.port,
      'password': c.auth,
      'tls': {
        'enabled': true,
        if (c.sni.isNotEmpty) 'server_name': c.sni,
        if (c.insecure) 'insecure': true,
      },
      if (c.obfs.isNotEmpty) 'obfs': {'type': c.obfs, 'password': c.obfsPassword},
    },
    _ => throw UnsupportedError('${proxy.protocolLabel} not yet supported on Windows'),
  };

  Map<String, dynamic> _vlessTls(VlessConfig c) {
    final tls = <String, dynamic>{'enabled': true};
    if (c.sni.isNotEmpty) tls['server_name'] = c.sni;
    if (c.fingerprint.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': c.fingerprint};
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
    String type, String path, String host, String grpcService, [String mode = '', String xPadding = '']
  ) => switch (type) {
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
      if (mode.isNotEmpty) 'mode': mode,
      'x_padding_bytes': xPadding.isNotEmpty ? xPadding : '100-1000',
    },
    _ => {'type': type},
  };
}
