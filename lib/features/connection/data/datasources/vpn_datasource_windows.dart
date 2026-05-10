import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:path_provider/path_provider.dart';

import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../settings/data/models/app_settings.dart';

class WindowsVpnDatasource {
  final void Function(V2RayStatus) onStatusChanged;
  Process? _sbProcess;
  StreamSubscription<String>? _statsSub;
  DateTime? _connectedAt;
  int _totalUp   = 0;
  int _totalDown = 0;
  bool _tunMode  = false;

  static const _socksPort  = 10808;
  static const _httpPort   = 10809;
  static const _clashPort  = 9090;

  WindowsVpnDatasource({required this.onStatusChanged});

  Future<void> initialize() async {}
  Future<bool> requestPermission() async => true;

  Future<void> start(ParsedProxy proxy, {ConnectionMode mode = ConnectionMode.tunnel}) async {
    await stop();
    _tunMode = mode == ConnectionMode.tunnel;

    final config  = _tunMode ? _buildTunConfig(proxy) : _buildProxyConfig(proxy);
    final tmp     = await getTemporaryDirectory();
    final cfgFile = File('${tmp.path}/honeyvpn_sb.json');
    await cfgFile.writeAsString(jsonEncode(config));

    final exeDir = File(Platform.resolvedExecutable).parent;
    final sbExe  = File('${exeDir.path}/sing-box.exe');
    if (!sbExe.existsSync()) {
      throw Exception('sing-box.exe not found at ${sbExe.path}');
    }

    onStatusChanged(V2RayStatus(state: 'CONNECTING'));

    final proc = await Process.start(
      sbExe.path, ['run', '-c', cfgFile.path],
      environment: {
        ...Platform.environment,
        'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
      },
    );
    _sbProcess = proc;
    _connectedAt = DateTime.now();
    _totalUp = 0;
    _totalDown = 0;

    final stderrBuf = StringBuffer();
    proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((s) => stderrBuf.write(s));

    proc.exitCode.then((code) {
      if (_sbProcess == proc) {
        _sbProcess = null;
        onStatusChanged(V2RayStatus(state: 'DISCONNECTED'));
      }
    });

    await Future.delayed(const Duration(milliseconds: 2000));

    if (_sbProcess == null) {
      final err = stderrBuf.toString().trim();
      final lastLine = err.isNotEmpty ? err.split('\n').last : 'unknown error';
      throw Exception('sing-box exited unexpectedly: $lastLine');
    }

    if (!_tunMode) {
      await _setSystemProxy('127.0.0.1', _httpPort);
    }

    onStatusChanged(V2RayStatus(state: 'CONNECTED'));

    _startStatsStream();
  }

  void _startStatsStream() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);

    Future(() async {
      try {
        final req  = await client.getUrl(
            Uri.parse('http://127.0.0.1:$_clashPort/traffic'));
        final resp = await req.close();

        _statsSub = resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
          if (line.trim().isEmpty) return;
          try {
            final data = json.decode(line) as Map<String, dynamic>;
            final up   = (data['up']   as num? ?? 0).toInt();
            final down = (data['down'] as num? ?? 0).toInt();
            _totalUp   += up;
            _totalDown += down;

            final elapsed = DateTime.now().difference(_connectedAt!);
            final h = elapsed.inHours.toString().padLeft(2, '0');
            final m = (elapsed.inMinutes  % 60).toString().padLeft(2, '0');
            final s = (elapsed.inSeconds  % 60).toString().padLeft(2, '0');

            onStatusChanged(V2RayStatus(
              state:         'CONNECTED',
              uploadSpeed:   up,
              downloadSpeed: down,
              upload:        _totalUp,
              download:      _totalDown,
              duration:      '$h:$m:$s',
            ));
          } catch (_) {}
        }, onError: (_) {});
      } catch (_) {
        // Clash API not available — fall back to a simple timer
        _startFallbackTimer();
      } finally {
        client.close();
      }
    });
  }

  // Fallback: update only the session clock if Clash API is unreachable
  Timer? _fallbackTimer;
  void _startFallbackTimer() {
    _fallbackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_connectedAt == null) return;
      final elapsed = DateTime.now().difference(_connectedAt!);
      final h = elapsed.inHours.toString().padLeft(2, '0');
      final m = (elapsed.inMinutes  % 60).toString().padLeft(2, '0');
      final s = (elapsed.inSeconds  % 60).toString().padLeft(2, '0');
      onStatusChanged(V2RayStatus(
        state: 'CONNECTED', duration: '$h:$m:$s',
      ));
    });
  }

  Future<void> stop() async {
    await _statsSub?.cancel();
    _statsSub = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _connectedAt   = null;
    _sbProcess?.kill();
    _sbProcess = null;
    try { await _clearSystemProxy(); } catch (_) {}
    onStatusChanged(V2RayStatus(state: 'DISCONNECTED'));
  }

  Future<int> ping(ParsedProxy proxy) async {
    try {
      final sw   = Stopwatch()..start();
      final sock = await Socket.connect(proxy.host, proxy.port,
          timeout: const Duration(seconds: 5));
      sw.stop();
      sock.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
  }

  void dispose() => stop();

  // ── System proxy ──────────────────────────────────────────────────────────

  Future<void> _setSystemProxy(String host, int port) async {
    const k =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    await Process.run('reg', ['add', k, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']);
    await Process.run('reg', ['add', k, '/v', 'ProxyServer',  '/t', 'REG_SZ',    '/d', '$host:$port', '/f']);
  }

  Future<void> _clearSystemProxy() async {
    const k =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    await Process.run('reg', ['add', k, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
  }

  // ── sing-box configs ──────────────────────────────────────────────────────

  Map<String, dynamic> _buildProxyConfig(ParsedProxy proxy) => {
    'log': {'level': 'warn'},
    'experimental': {
      'clash_api': {'external_controller': '127.0.0.1:$_clashPort'},
    },
    'inbounds': [
      {'type': 'socks', 'tag': 'socks-in', 'listen': '127.0.0.1', 'listen_port': _socksPort},
      {'type': 'http',  'tag': 'http-in',  'listen': '127.0.0.1', 'listen_port': _httpPort},
    ],
    'outbounds': [_buildOutbound(proxy), {'type': 'direct', 'tag': 'direct'}],
  };

  Map<String, dynamic> _buildTunConfig(ParsedProxy proxy) => {
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
        'address': ['172.19.0.1/30'],
        'auto_route': true,
        'strict_route': false,
        'stack': 'mixed',
        'sniff': true,
      },
    ],
    'outbounds': [
      _buildOutbound(proxy),
      {'type': 'direct', 'tag': 'direct'},
  
    ],
    'route': {
      'rules': [
        {'protocol': 'dns', 'action': 'hijack-dns'},
        {'ip_is_private': true,    'outbound': 'direct'},
      ],
      'final': 'proxy',
      'auto_detect_interface': true,
    },
  };

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
        'transport': _transport(c.transport, c.path, c.transportHost, c.grpcServiceName, c.xhttpMode),
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
      String type, String path, String host, String grpcService, [String mode = '']) =>
      switch (type) {
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
        'xhttp' => {
          'type': 'xhttp',
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'host': host,
          if (mode.isNotEmpty) 'mode': mode,
        },
        'httpupgrade' => {
          'type': 'httpupgrade',
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'host': host,
        },
        _ => {'type': type},
      };
}
