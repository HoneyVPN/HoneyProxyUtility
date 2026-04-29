import 'dart:convert';
import 'dart:io';

import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:path_provider/path_provider.dart';

import '../../../converter/domain/entities/parsed_proxy.dart';

class WindowsVpnDatasource {
  final void Function(V2RayStatus) onStatusChanged;
  Process? _xrayProcess;

  static const _socksPort = 10808;
  static const _httpPort  = 10809;

  WindowsVpnDatasource({required this.onStatusChanged});

  Future<void> initialize() async {}
  Future<bool> requestPermission() async => true;

  Future<void> start(ParsedProxy proxy) async {
    await stop();

    final config    = _buildXrayConfig(proxy);
    final tempDir   = await getTemporaryDirectory();
    final cfgFile   = File('${tempDir.path}/honeyvpn_xray.json');
    await cfgFile.writeAsString(jsonEncode(config));

    final exeDir  = File(Platform.resolvedExecutable).parent;
    final xrayExe = File('${exeDir.path}/xray.exe');
    if (!xrayExe.existsSync()) {
      throw Exception('xray.exe not found at ${xrayExe.path}');
    }

    onStatusChanged(const V2RayStatus(state: 'CONNECTING'));

    _xrayProcess = await Process.start(
      xrayExe.path,
      ['run', '-c', cfgFile.path],
    );

    // Give xray a moment to start
    await Future.delayed(const Duration(milliseconds: 1000));

    await _setSystemProxy('127.0.0.1', _httpPort);

    onStatusChanged(const V2RayStatus(state: 'CONNECTED'));
  }

  Future<void> stop() async {
    _xrayProcess?.kill();
    _xrayProcess = null;
    try {
      await _clearSystemProxy();
    } catch (_) {}
    onStatusChanged(const V2RayStatus(state: 'DISCONNECTED'));
  }

  Future<int> ping(ParsedProxy proxy) async {
    try {
      final sw = Stopwatch()..start();
      final sock = await Socket.connect(
        proxy.host, proxy.port,
        timeout: const Duration(seconds: 5),
      );
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
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    await Process.run('reg', ['add', key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']);
    await Process.run('reg', ['add', key, '/v', 'ProxyServer', '/t', 'REG_SZ',   '/d', '$host:$port', '/f']);
  }

  Future<void> _clearSystemProxy() async {
    const key =
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    await Process.run('reg', ['add', key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
  }

  // ── Xray config builder ───────────────────────────────────────────────────

  Map<String, dynamic> _buildXrayConfig(ParsedProxy proxy) => {
    'log': {'loglevel': 'warning'},
    'inbounds': [
      {
        'tag': 'socks',
        'port': _socksPort,
        'listen': '127.0.0.1',
        'protocol': 'socks',
        'settings': {'auth': 'noauth', 'udp': true},
      },
      {
        'tag': 'http',
        'port': _httpPort,
        'listen': '127.0.0.1',
        'protocol': 'http',
        'settings': {},
      },
    ],
    'outbounds': [_buildOutbound(proxy)],
  };

  Map<String, dynamic> _buildOutbound(ParsedProxy proxy) => switch (proxy) {
    VlessConfig c => {
      'protocol': 'vless',
      'settings': {
        'vnext': [{
          'address': c.host,
          'port': c.port,
          'users': [{'id': c.uuid, 'encryption': 'none', 'flow': c.flow}],
        }],
      },
      'streamSettings': _vlessStream(c),
    },
    VmessConfig c => {
      'protocol': 'vmess',
      'settings': {
        'vnext': [{
          'address': c.host,
          'port': c.port,
          'users': [{'id': c.uuid, 'alterId': c.alterId, 'security': c.security}],
        }],
      },
      'streamSettings': _vmessStream(c),
    },
    TrojanConfig c => {
      'protocol': 'trojan',
      'settings': {
        'servers': [{'address': c.host, 'port': c.port, 'password': c.password}],
      },
      'streamSettings': _trojanStream(c),
    },
    ShadowsocksConfig c => {
      'protocol': 'shadowsocks',
      'settings': {
        'servers': [{'address': c.host, 'port': c.port, 'method': c.method, 'password': c.password}],
      },
    },
    _ => throw UnsupportedError('${proxy.protocolLabel} not yet supported on Windows'),
  };

  Map<String, dynamic> _vlessStream(VlessConfig c) {
    final net = c.transport.isEmpty ? 'tcp' : c.transport;
    final m = <String, dynamic>{
      'network': net,
      'security': c.security,
    };
    if (c.security == 'reality') {
      m['realitySettings'] = {
        'serverName': c.sni,
        'fingerprint': c.fingerprint.isEmpty ? 'chrome' : c.fingerprint,
        'publicKey': c.publicKey,
        'shortId': c.shortId,
        'spiderX': c.spiderX.isEmpty ? '/' : c.spiderX,
      };
    } else if (c.security == 'tls') {
      m['tlsSettings'] = {
        'serverName': c.sni,
        if (c.fingerprint.isNotEmpty) 'fingerprint': c.fingerprint,

      };
    }
    _applyTransport(m, net, c.path, c.transportHost, c.grpcServiceName);
    return m;
  }

  Map<String, dynamic> _vmessStream(VmessConfig c) {
    final net = c.network.isEmpty ? 'tcp' : c.network;
    final m = <String, dynamic>{'network': net, 'security': c.tls};
    if (c.tls == 'tls') {
      m['tlsSettings'] = {'serverName': c.sni};
    }
    _applyTransport(m, net, c.path, c.wsHost, '');
    return m;
  }

  Map<String, dynamic> _trojanStream(TrojanConfig c) {
    final net = c.transport.isEmpty ? 'tcp' : c.transport;
    final m = <String, dynamic>{
      'network': net,
      'security': c.security.isEmpty ? 'tls' : c.security,
      'tlsSettings': {
        'serverName': c.sni,

        if (c.fingerprint.isNotEmpty) 'fingerprint': c.fingerprint,
      },
    };
    _applyTransport(m, net, c.path, c.transportHost, '');
    return m;
  }

  void _applyTransport(Map<String, dynamic> m, String net,
      String path, String host, String grpcService) {
    switch (net) {
      case 'ws':
        m['wsSettings'] = {
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'headers': {'Host': host},
        };
      case 'h2':
        m['httpSettings'] = {
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'host': [host],
        };
      case 'grpc':
        m['grpcSettings'] = {'serviceName': grpcService};
      case 'xhttp':
        m['xhttpSettings'] = {
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'host': host,
          'mode': 'stream-one',
        };
      case 'httpupgrade':
        m['httpUpgradeSettings'] = {
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'host': host,
        };
    }
  }
}
