import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HttpClient, Platform, Process, ServerSocket, Socket;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/server_profile_model.dart';
import '../../../connection/data/singbox/singbox_config_generator.dart';
import '../../../converter/data/parsers/link_dispatcher.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';

const _serversKey = 'honeyvpn_servers';

final serversNotifierProvider =
    AsyncNotifierProvider<ServersNotifier, List<ServerProfileModel>>(
  ServersNotifier.new,
);

// Read-only computed provider — always reflects isSelected from the server list
final selectedServerProvider = Provider<ServerProfileModel?>((ref) {
  final servers = ref.watch(serversNotifierProvider).value ?? [];
  if (servers.isEmpty) return null;
  return servers.firstWhere((s) => s.isSelected, orElse: () => servers.first);
});

class ServersNotifier extends AsyncNotifier<List<ServerProfileModel>> {
  @override
  Future<List<ServerProfileModel>> build() => _load();

  Future<List<ServerProfileModel>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_serversKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      // latencyMs intentionally stripped — stale ping values should not persist across sessions
      return ServerProfileModel.listFromJson(raw)
          .map((s) => ServerProfileModel(
                id: s.id,
                protocol: s.protocol,
                name: s.name,
                host: s.host,
                port: s.port,
                configJson: s.configJson,
                subscriptionId: s.subscriptionId,
                addedAt: s.addedAt,
                isSelected: s.isSelected,
                isFavorite: s.isFavorite,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<ServerProfileModel> models) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serversKey, ServerProfileModel.listToJson(models));
  }

  Future<void> addFromProxy(ParsedProxy proxy, {String subscriptionId = ''}) async {
    final current = state.value ?? [];
    final id = current.isEmpty
        ? DateTime.now().millisecondsSinceEpoch
        : current.map((s) => s.id).reduce((a, b) => a > b ? a : b) + 1;
    final model = ServerProfileModel(
      id: id,
      protocol: _protocolTag(proxy),
      name: proxy.displayName,
      host: proxy.host,
      port: proxy.port,
      configJson: json.encode({'rawLink': _rawLink(proxy)}),
      subscriptionId: subscriptionId,
      addedAt: DateTime.now(),
    );
    final updated = [...current, model];
    await _save(updated);
    state = AsyncData(updated);
  }

  Future<void> addFromProxies(List<ParsedProxy> proxies, {String subscriptionId = ''}) async {
    final current = state.value ?? [];
    // Deduplicate by protocol+host+port to avoid false positives from same host on different protocols
    final existingKeys = current.map((s) => '${s.protocol}:${s.host}:${s.port}').toSet();
    var nextId = current.isEmpty
        ? DateTime.now().millisecondsSinceEpoch
        : current.map((s) => s.id).reduce((a, b) => a > b ? a : b) + 1;
    final newModels = <ServerProfileModel>[];
    for (final p in proxies) {
      final key = '${_protocolTag(p)}:${p.host}:${p.port}';
      if (existingKeys.contains(key) && subscriptionId.isEmpty) continue;
      newModels.add(ServerProfileModel(
        id: nextId++,
        protocol: _protocolTag(p),
        name: p.displayName,
        host: p.host,
        port: p.port,
        configJson: json.encode({'rawLink': _rawLink(p)}),
        subscriptionId: subscriptionId,
        addedAt: DateTime.now(),
      ));
    }
    if (newModels.isEmpty) return;
    final updated = [...current, ...newModels];
    await _save(updated);
    state = AsyncData(updated);
  }

  Future<void> delete(int id) async {
    final current = state.value ?? [];
    final updated = current.where((s) => s.id != id).toList();
    await _save(updated);
    state = AsyncData(updated);
  }

  Future<void> deleteAll(List<int> ids) async {
    final current = state.value ?? [];
    final idSet = ids.toSet();
    final updated = current.where((s) => !idSet.contains(s.id)).toList();
    await _save(updated);
    state = AsyncData(updated);
  }

  Future<void> selectServer(ServerProfileModel server) async {
    final current = state.value ?? [];
    final updated = current.map((s) => s.copyWith(isSelected: s.id == server.id)).toList();
    await _save(updated);
    state = AsyncData(updated);
  }

  static const _nativeChannel = MethodChannel('ru.honeyvpn.proxy/native');
  static final _dispatcher = const LinkDispatcher();

  Future<void> updateLatency(int id, double ms) async {
    final current = state.value ?? [];
    final updated = current.map((s) => s.id == id ? s.copyWith(latencyMs: ms) : s).toList();
    await _save(updated);
    state = AsyncData(updated);
  }

  Future<double> testLatency(ServerProfileModel server) async {
    final ms = await _testServerLatency(server);
    await updateLatency(server.id, ms);
    return ms;
  }

  Future<double> _testServerLatency(ServerProfileModel server) async {
    try {
      final raw = (jsonDecode(server.configJson) as Map<String, dynamic>)['rawLink'] as String?;
      if (raw != null) {
        final proxy = _dispatcher.dispatch(raw);
        return await _pingProxy(proxy);
      }
    } catch (_) {}
    return -1;
  }

  Future<double> _pingProxy(ParsedProxy proxy) async {
    if (Platform.isAndroid) return _pingAndroid(proxy);
    return _pingTcp(proxy.host, proxy.port);
  }

  Future<double> _pingAndroid(ParsedProxy proxy) async {
    // Get sing-box binary path via native channel
    String? libDir;
    try {
      libDir = await _nativeChannel.invokeMethod<String>('getNativeLibDir');
    } catch (_) {}
    if (libDir == null) return -1;

    final sbPath = '$libDir/libsingbox.so';
    if (!File(sbPath).existsSync()) return -1;

    // Bind port 0 to let the OS pick a free port, then release it for sing-box
    int apiPort;
    try {
      final ss = await ServerSocket.bind('127.0.0.1', 0);
      apiPort = ss.port;
      await ss.close();
    } catch (_) {
      return -1;
    }

    String configJson;
    try {
      configJson = SingboxConfigGenerator().generateForPing(proxy, apiPort);
    } catch (_) {
      return -1;
    }

    final dir = await getTemporaryDirectory();
    final cfgFile = File('${dir.path}/sbping_$apiPort.json');

    Process? process;
    try {
      await cfgFile.writeAsString(configJson);
      process = await Process.start(sbPath, ['run', '-c', cfgFile.path]);
      // Drain output streams to prevent the process from blocking on a full pipe buffer
      process.stdout.drain<void>();
      process.stderr.drain<void>();

      if (!await _waitForPort('127.0.0.1', apiPort, 8000)) return -1;

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      try {
        final req = await client.getUrl(Uri.parse(
          'http://127.0.0.1:$apiPort/proxies/proxy/delay'
          '?timeout=5000&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204',
        ));
        final resp = await req.close().timeout(const Duration(seconds: 7));
        if (resp.statusCode == 200) {
          final body = await resp.transform(const Utf8Decoder()).join();
          final data = jsonDecode(body) as Map<String, dynamic>;
          return (data['delay'] as num).toDouble();
        }
        return -1;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return -1;
    } finally {
      process?.kill();
      try { cfgFile.deleteSync(); } catch (_) {}
    }
  }



  Future<bool> _waitForPort(String host, int port, int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final s = await Socket.connect(host, port,
            timeout: const Duration(milliseconds: 300));
        await s.close();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return false;
  }

  Future<double> _pingTcp(String host, int port) async {
    Socket? sock;
    final sw = Stopwatch()..start();
    try {
      sock = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      sw.stop();
      return sw.elapsedMilliseconds.toDouble();
    } catch (_) {
      return -1;
    } finally {
      sw.stop();
      await sock?.close();
    }
  }

  // Sequential to avoid spawning many sing-box processes simultaneously.
  // UI updates after each server completes, so users see pings appear one by one.
  Future<void> testAllLatency() async {
    final servers = List<ServerProfileModel>.of(state.value ?? []);
    for (final s in servers) {
      if (s.protocol == 'awg') continue;
      try { await testLatency(s); } catch (_) {}
    }
  }

  Future<void> replaceSubscription(String subscriptionId, List<ParsedProxy> proxies) async {
    final current = state.value ?? [];
    // Remove old servers from this subscription
    final kept = current.where((s) => s.subscriptionId != subscriptionId).toList();
    // Add new ones
    var nextId = kept.isEmpty
        ? DateTime.now().millisecondsSinceEpoch
        : kept.map((s) => s.id).reduce((a, b) => a > b ? a : b) + 1;
    final newModels = proxies.map((p) => ServerProfileModel(
      id: nextId++,
      protocol: _protocolTag(p),
      name: p.displayName,
      host: p.host,
      port: p.port,
      configJson: json.encode({'rawLink': _rawLink(p)}),
      subscriptionId: subscriptionId,
      addedAt: DateTime.now(),
    )).toList();
    final updated = [...kept, ...newModels];
    await _save(updated);
    state = AsyncData(updated);
  }

  Future<void> deleteBySubscription(String subscriptionId) async {
    final current = state.value ?? [];
    final updated = current.where((s) => s.subscriptionId != subscriptionId).toList();
    await _save(updated);
    state = AsyncData(updated);
  }

  static String _protocolTag(ParsedProxy p) => switch (p) {
    VmessConfig _ => 'vmess',
    VlessConfig _ => 'vless',
    TrojanConfig _ => 'trojan',
    ShadowsocksConfig _ => 'ss',
    Hysteria2Config _ => 'hy2',
    TuicConfig _ => 'tuic',
    WireGuardConfig _ => 'wg',
    AmneziaWGConfig _ => 'awg',
    NaiveConfig _ => 'naive',
    ShadowTlsConfig _ => 'shadowtls',
  };

  static String _rawLink(ParsedProxy p) {
    return switch (p) {
      VlessConfig c => () {
          final params = <String, String>{
            'encryption': c.encryption.isEmpty ? 'none' : c.encryption,
            'security': c.security,
            if (c.sni.isNotEmpty) 'sni': c.sni,
            if (c.fingerprint.isNotEmpty) 'fp': c.fingerprint,
            if (c.publicKey.isNotEmpty) 'pbk': c.publicKey,
            if (c.shortId.isNotEmpty) 'sid': c.shortId,
            if (c.spiderX.isNotEmpty) 'spx': Uri.encodeComponent(c.spiderX),
            'type': c.transport.isEmpty ? 'tcp' : c.transport,
            if (c.path.isNotEmpty) 'path': Uri.encodeComponent(c.path),
            if (c.transportHost.isNotEmpty) 'host': c.transportHost,
            if (c.grpcServiceName.isNotEmpty) 'serviceName': c.grpcServiceName,
            if (c.flow.isNotEmpty) 'flow': c.flow,
            if (c.xhttpMode.isNotEmpty) 'mode': c.xhttpMode,
            if (c.xPaddingBytes.isNotEmpty) 'xPaddingBytes': c.xPaddingBytes,
          };
          final q = params.entries.map((e) => '${e.key}=${e.value}').join('&');
          return 'vless://${c.uuid}@${c.host}:${c.port}?$q#${Uri.encodeComponent(c.name)}';
        }(),
      VmessConfig c => () {
          final j = json.encode({
            'v': '2', 'ps': c.name, 'add': c.host, 'port': c.port.toString(),
            'id': c.uuid, 'aid': c.alterId.toString(), 'scy': c.security,
            'net': c.network, 'type': 'none', 'host': c.wsHost, 'path': c.path,
            'tls': c.tls, 'sni': c.sni, 'alpn': c.alpn, 'fp': c.fingerprint,
          });
          return 'vmess://${base64Encode(utf8.encode(j))}';
        }(),
      TrojanConfig c => () {
          final params = <String, String>{
            'security': c.security,
            if (c.sni.isNotEmpty) 'sni': c.sni,
            if (c.alpn.isNotEmpty) 'alpn': c.alpn,
            if (c.fingerprint.isNotEmpty) 'fp': c.fingerprint,
            'type': c.transport.isEmpty ? 'tcp' : c.transport,
            if (c.path.isNotEmpty) 'path': Uri.encodeComponent(c.path),
            if (c.transportHost.isNotEmpty) 'host': c.transportHost,
          };
          final q = params.entries.map((e) => '${e.key}=${e.value}').join('&');
          return 'trojan://${c.password}@${c.host}:${c.port}?$q#${Uri.encodeComponent(c.name)}';
        }(),
      ShadowsocksConfig c => () {
          final userInfo = base64Encode(utf8.encode('${c.method}:${c.password}'));
          final plug = c.plugin.isNotEmpty
              ? '/?plugin=${Uri.encodeComponent('${c.plugin};${c.pluginOpts}')}'
              : '';
          return 'ss://$userInfo@${c.host}:${c.port}$plug#${Uri.encodeComponent(c.name)}';
        }(),
      Hysteria2Config c => () {
          final params = <String, String>{
            if (c.sni.isNotEmpty) 'sni': c.sni,
            if (c.insecure) 'insecure': '1',
            if (c.obfs.isNotEmpty) 'obfs': c.obfs,
            if (c.obfsPassword.isNotEmpty) 'obfs-password': c.obfsPassword,
            if (c.pinSha256.isNotEmpty) 'pinSHA256': c.pinSha256,
            if (c.ports != null && c.ports!.isNotEmpty) 'mport': c.ports!,
          };
          final q = params.isEmpty ? '' : '?${params.entries.map((e) => "${e.key}=${e.value}").join("&")}';
          return 'hy2://${c.auth}@${c.host}:${c.port}$q#${Uri.encodeComponent(c.name)}';
        }(),
      TuicConfig c => () {
          final params = <String, String>{
            if (c.sni.isNotEmpty) 'sni': c.sni,
            if (c.alpn.isNotEmpty) 'alpn': c.alpn,
            if (c.congestionControl.isNotEmpty) 'congestion_control': c.congestionControl,
            if (c.udpRelayMode.isNotEmpty) 'udp_relay_mode': c.udpRelayMode,
            if (c.allowInsecure) 'allow_insecure': '1',
          };
          final q = params.isEmpty ? '' : '?${params.entries.map((e) => "${e.key}=${e.value}").join("&")}';
          return 'tuic://${c.uuid}:${c.password}@${c.host}:${c.port}$q#${Uri.encodeComponent(c.name)}';
        }(),
      WireGuardConfig c => () {
          final data = json.encode({
            'privateKey': c.privateKey, 'publicKey': c.publicKey,
            'presharedKey': c.presharedKey, 'addresses': c.addresses,
            'dns': c.dns, 'mtu': c.mtu,
            if (c.reserved != null) 'reserved': c.reserved,
          });
          return 'wireguard://${c.host}:${c.port}?config=${Uri.encodeComponent(data)}#${Uri.encodeComponent(c.name)}';
        }(),
      AmneziaWGConfig c => () {
          final data = json.encode({
            'privateKey': c.privateKey, 'publicKey': c.publicKey,
            'presharedKey': c.presharedKey, 'addresses': c.addresses,
            'dns': c.dns, 'mtu': c.mtu,
            if (c.reserved != null) 'reserved': c.reserved,
            'jc': c.jc, 'jmin': c.jmin, 'jmax': c.jmax,
            's1': c.s1, 's2': c.s2, 's3': c.s3, 's4': c.s4,
            'h1': c.h1, 'h2': c.h2, 'h3': c.h3, 'h4': c.h4,
          });
          return 'awg://${c.host}:${c.port}?config=${Uri.encodeComponent(data)}#${Uri.encodeComponent(c.name)}';
        }(),
      NaiveConfig c =>
          '${c.scheme}://${c.username}:${c.password}@${c.host}:${c.port}#${Uri.encodeComponent(c.name)}',
      ShadowTlsConfig c => () {
          final data = json.encode({
            'password': c.password, 'sni': c.sni, 'version': c.version,
            'inner': _rawLink(c.innerProxy),
          });
          return 'shadowtls://${c.host}:${c.port}?config=${Uri.encodeComponent(data)}#${Uri.encodeComponent(c.name)}';
        }(),
    };
  }
}
