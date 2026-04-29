import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/server_profile_model.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';

const _serversKey = 'nexproxy_servers';

final serversNotifierProvider =
    AsyncNotifierProvider<ServersNotifier, List<ServerProfileModel>>(
  ServersNotifier.new,
);

final selectedServerProvider = StateProvider<ServerProfileModel?>((ref) {
  final servers = ref.watch(serversNotifierProvider).value ?? [];
  try {
    return servers.firstWhere((s) => s.isSelected);
  } catch (_) {
    return servers.isEmpty ? null : servers.first;
  }
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
    final id = DateTime.now().millisecondsSinceEpoch;
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
    final existingHosts = current.map((s) => '${s.host}:${s.port}').toSet();
    var nextId = DateTime.now().millisecondsSinceEpoch;
    final newModels = <ServerProfileModel>[];
    for (final p in proxies) {
      final key = '${p.host}:${p.port}';
      if (existingHosts.contains(key) && subscriptionId.isEmpty) continue;
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

  Future<double> testLatency(ServerProfileModel server) async {
    // hy2/tuic use QUIC (UDP) — TCP-ping their port will timeout;
    // use port 443 as a reachability probe instead.
    final pingPort = (server.protocol == 'hy2' || server.protocol == 'tuic') ? 443 : server.port;
    try {
      final resp = await Dio().get<Map<String, dynamic>>(
        '/proxy/ping',
        queryParameters: {'host': server.host, 'port': pingPort},
        options: Options(receiveTimeout: const Duration(seconds: 8)),
      );
      final result = resp.data ?? {};
      if (result.containsKey('error')) throw Exception(result['error']);
      final ms = (result['ms'] as num).toDouble();
      await updateLatency(server.id, ms);
      return ms;
    } catch (_) {
      await updateLatency(server.id, -1);
      return -1;
    }
  }

  Future<void> testAllLatency() async {
    final servers = state.value ?? [];
    await Future.wait(servers.map(testLatency));
  }

  Future<void> replaceSubscription(String subscriptionId, List<ParsedProxy> proxies) async {
    final current = state.value ?? [];
    // Remove old servers from this subscription
    final kept = current.where((s) => s.subscriptionId != subscriptionId).toList();
    // Add new ones
    var nextId = DateTime.now().millisecondsSinceEpoch;
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
    return '';
  }
}
