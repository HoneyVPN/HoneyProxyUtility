import 'dart:convert';
import 'dart:io' show Socket;

import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/server_profile_model.dart';
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
      return ServerProfileModel.listFromJson(raw);
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

  Future<void> updateLatency(int id, double ms) async {
    final current = state.value ?? [];
    final updated = current.map((s) => s.id == id ? s.copyWith(latencyMs: ms) : s).toList();
    await _save(updated);
    state = AsyncData(updated);
  }

  static const _vpnChannel = MethodChannel('ru.honeyvpn.proxy/vpn');

  Future<double> testLatency(ServerProfileModel server) async {
    final udpOnly = server.protocol == 'hy2' || server.protocol == 'tuic';
    final ms = udpOnly
        ? await _pingIcmp(server.host)
        : await _pingTcp(server.host, server.port);
    await updateLatency(server.id, ms);
    return ms;
  }

  Future<double> _pingTcp(String host, int port) async {
    Socket? sock;
    try {
      final sw = Stopwatch()..start();
      sock = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      sw.stop();
      return sw.elapsedMilliseconds.toDouble();
    } catch (_) {
      return -1;
    } finally {
      await sock?.close();
    }
  }

  Future<double> _pingIcmp(String host) async {
    try {
      final ms = await _vpnChannel.invokeMethod<int>('pingHost', {
        'host': host,
        'timeout': 3000,
      });
      return ms?.toDouble() ?? -1.0;
    } catch (_) {
      return -1.0;
    }
  }

  Future<void> testAllLatency() async {
    final servers = List<ServerProfileModel>.of(state.value ?? []);
    await Future.wait(servers.map((s) async {
      try {
        await testLatency(s);
      } catch (_) {}
    }));
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
