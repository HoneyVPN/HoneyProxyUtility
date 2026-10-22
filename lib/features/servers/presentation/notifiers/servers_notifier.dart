import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/server_profile_model.dart';
import '../../data/services/profile_latency_service.dart';
import '../../../converter/data/parsers/link_dispatcher.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../subscriptions/data/services/proxy_identity.dart';
import '../../../subscriptions/data/services/subscription_policy.dart';
import '../../../subscriptions/data/models/subscription_model.dart';
import '../../../subscriptions/domain/entities/free_server_snapshot.dart';

const _serversKey = 'honeyvpn_servers';
const _freeRemovedKey = 'honeyvpn_free_server_removed_v1';

bool _needsProfileWorker(
  List<ServerProfileModel> profiles, {
  int incomingCount = 0,
}) {
  if (profiles.length + incomingCount >= 50) return true;
  var characters = 0;
  for (final profile in profiles) {
    characters += profile.configJson.length;
    if (characters >= 64 * 1024) return true;
  }
  return false;
}

typedef _SubscriptionSnapshotInput = ({
  List<ServerProfileModel> current,
  List<ParsedProxy> proxies,
  String source,
});

List<ParsedProxy> _distinctSubscriptionProxies(List<ParsedProxy> proxies) =>
    subscriptionProxies('', proxies);

final builtInFreeRandomProvider = Provider<Random>((ref) => Random());

final builtInFreeServerPresentProvider = Provider<bool>((ref) {
  final profiles = ref.watch(serversNotifierProvider).value ?? [];
  return profiles.any((s) => s.subscriptionId == builtInSubscriptionUrl);
});

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

final profileLatencyServiceProvider = Provider<ProfileLatencyService>(
  (ref) => IsolatedCoreLatencyService(),
);

class LatencyTestProgress {
  const LatencyTestProgress({
    this.isRunning = false,
    this.completed = 0,
    this.total = 0,
    this.activeIds = const {},
  });

  final bool isRunning;
  final int completed;
  final int total;
  final Set<int> activeIds;
}

final latencyTestProgressProvider =
    NotifierProvider<LatencyTestProgressNotifier, LatencyTestProgress>(
      LatencyTestProgressNotifier.new,
    );

class LatencyTestProgressNotifier extends Notifier<LatencyTestProgress> {
  @override
  LatencyTestProgress build() => const LatencyTestProgress();

  void update(LatencyTestProgress progress) => state = progress;
}

class ServersNotifier extends AsyncNotifier<List<ServerProfileModel>> {
  Future<void> _pendingMutation = Future<void>.value();
  Future<void>? _latencyBatch;
  final _latencyCancellations = <LatencyCancellation>{};
  LatencyCancellation? _batchCancellation;
  final _profileGenerations = <int, int>{};
  var _nextProfileGeneration = 0;
  var _freeRevision = 0;
  var _freeRemoved = false;

  /// Serialize read/modify/write operations, including latency callbacks. A
  /// refresh must not overwrite another subscription or a concurrent selection.
  Future<List<ServerProfileModel>> _update(
    FutureOr<List<ServerProfileModel>> Function(List<ServerProfileModel>)
    transform, {
    Future<void> Function()? afterSave,
    bool persist = true,
  }) {
    final operation = _pendingMutation.then((_) async {
      await future;
      final before = state.requireValue;
      final updated = await transform(before);
      if (!persist && identical(updated, before)) return before;
      // Ping samples are session state. Serializing and rewriting every proxy
      // configuration for each sample stalls large batches on the UI isolate.
      if (persist) await _save(updated);
      await afterSave?.call();
      if (ref.mounted) {
        final previous = {for (final profile in before) profile.id: profile};
        final updatedIds = updated.map((profile) => profile.id).toSet();
        _profileGenerations.removeWhere((id, _) => !updatedIds.contains(id));
        for (final profile in updated) {
          final old = previous[profile.id];
          if (old == null ||
              old.configJson != profile.configJson ||
              old.subscriptionId != profile.subscriptionId ||
              old.addedAt != profile.addedAt) {
            _profileGenerations[profile.id] = ++_nextProfileGeneration;
          }
        }
        state = AsyncData(updated);
      }
      return updated;
    });
    // A failed write must not prevent subsequent operations from running.
    _pendingMutation = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  @override
  Future<List<ServerProfileModel>> build() {
    ref.onDispose(() {
      _batchCancellation?.cancel();
      for (final cancellation in _latencyCancellations) {
        cancellation.cancel();
      }
    });
    return _load().then((profiles) {
      for (final profile in profiles) {
        _profileGenerations[profile.id] = ++_nextProfileGeneration;
      }
      return profiles;
    });
  }

  Future<List<ServerProfileModel>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // Legacy setters change their cache before a platform write can fail.
    // Refresh the platform snapshot before provider recreation. Some platforms,
    // including Windows, return a backend cache rather than rereading disk;
    // failed mutations restore their own key separately. Keep this read awaited
    // so it cannot replace the cache after a subsequent successful mutation.
    await prefs.reload();
    final raw = prefs.getString(_serversKey);
    List<ServerProfileModel> loaded;
    try {
      loaded = raw == null || raw.isEmpty
          ? <ServerProfileModel>[]
          : ServerProfileModel.listFromJson(raw);
    } catch (_) {
      loaded = [];
    }
    // latencyMs intentionally stripped — stale ping values should not persist.
    final normalized = loaded
        .map(
          (s) => ServerProfileModel(
            id: s.id,
            protocol: s.protocol,
            name: s.name,
            host: s.host,
            port: s.port,
            configJson: s.configJson,
            subscriptionId: normalizeSubscriptionUrl(s.subscriptionId),
            addedAt: s.addedAt,
            isSelected: s.isSelected,
            isFavorite: s.isFavorite,
          ),
        )
        .toList();
    final free = normalized
        .where((s) => s.subscriptionId == builtInSubscriptionUrl)
        .toList();
    final removed = prefs.getBool(_freeRemovedKey);
    if (removed != null) {
      _freeRemoved = removed;
    } else {
      // Old releases did not persist deletion intent. With no free profile,
      // a previous successful fetch is the only evidence of a user removal.
      // Conservatively preserve that absence. A first failed fetch (without
      // a success timestamp) remains eligible for startup/automatic retries.
      _freeRemoved = free.isEmpty && _hadSuccessfulFreeFeed(prefs);
      await _saveFreeRemoved(_freeRemoved);
    }
    if (_freeRemoved) {
      normalized.removeWhere((s) => s.subscriptionId == builtInSubscriptionUrl);
    }
    // Repair legacy free-feed imports even when the network is unavailable.
    if (!_freeRemoved && free.length > 1) {
      final retained =
          free.where((s) => s.isSelected).firstOrNull ??
          free.where((s) => s.isFavorite).firstOrNull ??
          free.first;
      normalized.removeWhere(
        (s) =>
            s.subscriptionId == builtInSubscriptionUrl &&
            !identical(s, retained),
      );
    }
    if (normalized.length != loaded.length ||
        loaded.any(
          (s) => s.subscriptionId != normalizeSubscriptionUrl(s.subscriptionId),
        )) {
      await _save(normalized);
    }
    return normalized;
  }

  static bool _hadSuccessfulFreeFeed(SharedPreferences prefs) {
    final raw = prefs.getString('nexproxy_subscriptions');
    if (raw == null) return false;
    try {
      return SubscriptionModel.listFromJson(raw).any(
        (sub) =>
            normalizeSubscriptionUrl(sub.url) == builtInSubscriptionUrl &&
            sub.lastUpdated != null,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveFreeRemoved(bool removed) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getBool(_freeRemovedKey);
    try {
      if (!await prefs.setBool(_freeRemovedKey, removed)) {
        throw StateError('Failed to save free server preference');
      }
    } catch (error, stack) {
      // Restore this key's known value once; a failed restoration is not proof
      // of durable storage. Never undo a separately committed profile mutation.
      try {
        if (previous == null) {
          await prefs.remove(_freeRemovedKey);
        } else {
          await prefs.setBool(_freeRemovedKey, previous);
        }
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
    _freeRemoved = removed;
  }

  /// Read-only publication lease for dependent subscription metadata.
  /// Removing/rotating the free slot retires an in-flight geo bundle too.
  bool isCurrentFreeServerSnapshot(FreeServerSnapshot snapshot) =>
      snapshot.revision == _freeRevision && snapshot.removed == _freeRemoved;

  Future<FreeServerSnapshot> freeServerSnapshot() async {
    await future;
    await _pendingMutation;
    return FreeServerSnapshot(
      revision: _freeRevision,
      removed: _freeRemoved,
      present: state.requireValue.any(
        (s) => s.subscriptionId == builtInSubscriptionUrl,
      ),
    );
  }

  Future<void> _recordFreeRemoval(List<ServerProfileModel> removed) async {
    if (!removed.any((s) => s.subscriptionId == builtInSubscriptionUrl)) return;
    // Save the tombstone first. If profile storage then fails or the process
    // exits between writes, startup removes the stale profile, not the intent.
    await _saveFreeRemoved(true);
    _freeRevision++;
  }

  Future<void> _save(List<ServerProfileModel> models) async {
    final encoded = _needsProfileWorker(models)
        ? await compute(
            ServerProfileModel.listToJson,
            models,
            debugLabel: 'save-server-profiles',
          )
        : ServerProfileModel.listToJson(models);
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_serversKey);
    try {
      if (!await prefs.setString(_serversKey, encoded)) {
        throw StateError('Failed to save server profiles');
      }
    } catch (error, stack) {
      // Legacy setters may mutate both Dart and Windows backend caches before
      // failing. Restore only this key once, preserving a committed opt-out.
      try {
        if (previous == null) {
          await prefs.remove(_serversKey);
        } else {
          await prefs.setString(_serversKey, previous);
        }
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> addFromProxy(ParsedProxy proxy, {String subscriptionId = ''}) =>
      addFromProxies([proxy], subscriptionId: subscriptionId);

  Future<void> addFromProxies(
    List<ParsedProxy> proxies, {
    String subscriptionId = '',
  }) async {
    final source = normalizeSubscriptionUrl(subscriptionId);
    if (source.isNotEmpty) {
      // Re-importing a feed replaces its previous snapshot instead of appending.
      await replaceSubscription(source, proxies);
      return;
    }
    await _update((current) {
      final existingKeys = current
          .where((s) => s.subscriptionId.isEmpty)
          .map(_profileIdentity)
          .whereType<String>()
          .toSet();
      var nextId = _nextId(current);
      final newModels = <ServerProfileModel>[];
      for (final p in proxies) {
        if (!existingKeys.add(proxyIdentity(p))) continue;
        newModels.add(_modelFromProxy(p, nextId++, ''));
      }
      return [...current, ...newModels];
    });
  }

  Future<void> delete(int id, {String? expectedSubscriptionId}) async {
    final source = expectedSubscriptionId == null
        ? null
        : normalizeSubscriptionUrl(expectedSubscriptionId);
    if (source == builtInSubscriptionUrl) {
      // Confirmation dialogs hold a snapshot. A refresh may rotate its ID
      // before the user confirms; the intent still removes the one free node.
      await deleteBySubscription(source!);
      return;
    }
    bool matches(ServerProfileModel profile) =>
        profile.id == id &&
        (source == null || profile.subscriptionId == source);
    await _update((current) async {
      await _recordFreeRemoval(current.where(matches).toList());
      return current.where((s) => !matches(s)).toList();
    });
  }

  Future<void> deleteAll(
    List<int> ids, {
    String? expectedSubscriptionId,
  }) async {
    final source = expectedSubscriptionId == null
        ? null
        : normalizeSubscriptionUrl(expectedSubscriptionId);
    if (source == builtInSubscriptionUrl) {
      await deleteBySubscription(source!);
      return;
    }
    final idSet = ids.toSet();
    bool matches(ServerProfileModel profile) =>
        idSet.contains(profile.id) &&
        (source == null || profile.subscriptionId == source);
    await _update((current) async {
      await _recordFreeRemoval(current.where(matches).toList());
      return current.where((s) => !matches(s)).toList();
    });
  }

  Future<void> selectServer(ServerProfileModel server) async {
    await _update(
      (current) => current
          .map((s) => s.copyWith(isSelected: s.id == server.id))
          .toList(),
    );
  }

  /// A native popup can outlive a refresh or deletion. Validate its captured
  /// profile inside the same serialized mutation that saves the selection.
  Future<bool> selectServerIfCurrent(ServerProfileModel expected) async {
    var matched = false;
    await _update((current) {
      matched = current.any(expected.hasSameConnectionIdentity);
      if (!matched) return current;
      return current
          .map(
            (profile) =>
                profile.copyWith(isSelected: profile.id == expected.id),
          )
          .toList();
    });
    return matched;
  }

  /// Apply the menu's explicit choice only to its captured connection. IDs can
  /// be reused or refreshed while the menu is open; presentation updates such
  /// as selection and latency must not make that snapshot stale.
  Future<bool> setFavoriteIfCurrent(
    ServerProfileModel expected,
    bool isFavorite,
  ) async {
    var matched = false;
    await _update((current) {
      matched = current.any(expected.hasSameConnectionIdentity);
      if (!matched) return current;
      return current
          .map(
            (profile) => expected.hasSameConnectionIdentity(profile)
                ? profile.copyWith(isFavorite: isFavorite)
                : profile,
          )
          .toList();
    });
    return matched;
  }

  static final _dispatcher = const LinkDispatcher();

  Future<void> updateLatency(int id, double ms) async {
    await _update(
      (current) => current
          .map((s) => s.id == id ? s.copyWith(latencyMs: ms) : s)
          .toList(),
      persist: false,
    );
  }

  Future<double> testLatency(ServerProfileModel server) async {
    final cancellation = LatencyCancellation();
    final generation = _profileGenerations[server.id];
    _latencyCancellations.add(cancellation);
    try {
      final raw =
          (jsonDecode(server.configJson) as Map<String, dynamic>)['rawLink']
              as String?;
      final ms = raw == null
          ? -1.0
          : await ref
                .read(profileLatencyServiceProvider)
                .measure(_dispatcher.dispatch(raw), cancellation: cancellation);
      if (!cancellation.isCancelled && ref.mounted) {
        await _update((current) {
          // Refreshes can delete/reuse IDs or replace a node while its probe is
          // in flight. Never attach an old result to a different profile.
          if (_profileGenerations[server.id] != generation) return current;
          final index = current.indexWhere(
            (existing) =>
                existing.id == server.id &&
                existing.configJson == server.configJson &&
                existing.subscriptionId == server.subscriptionId,
          );
          if (index < 0) return current;
          final updated = [...current];
          updated[index] = current[index].copyWith(latencyMs: ms);
          return updated;
        }, persist: false);
      }
      return ms;
    } catch (_) {
      return -1;
    } finally {
      _latencyCancellations.remove(cancellation);
    }
  }

  /// Cancel closes active loopback requests and retires each owned probe core.
  /// Completed results remain visible; cancellation does not mark nodes dead.
  Future<void> cancelLatencyTests() async {
    _batchCancellation?.cancel();
    for (final cancellation in _latencyCancellations.toList()) {
      cancellation.cancel();
    }
    await _latencyBatch;
  }

  // Repeated button taps join one batch. Bound native process count; each result
  // still updates immediately, and all protocols have an explicit outcome.
  Future<void> testAllLatency() {
    if (_latencyBatch != null) return _latencyBatch!;
    final operation = _runLatencyBatch();
    _latencyBatch = operation;
    return operation.whenComplete(() {
      if (identical(_latencyBatch, operation)) _latencyBatch = null;
    });
  }

  Future<void> _runLatencyBatch() async {
    final cancellation = LatencyCancellation();
    _batchCancellation = cancellation;
    final activeIds = <int>{};
    var completed = 0;
    var total = 0;
    void publish({bool running = true}) {
      if (!ref.mounted) return;
      ref
          .read(latencyTestProgressProvider.notifier)
          .update(
            LatencyTestProgress(
              isRunning: running,
              completed: completed,
              total: total,
              activeIds: Set<int>.unmodifiable(activeIds),
            ),
          );
    }

    publish();
    try {
      final servers = await future;
      total = servers.length;
      publish();
      final iterator = servers.iterator;
      Future<void> worker() async {
        while (!cancellation.isCancelled && iterator.moveNext()) {
          final server = iterator.current;
          activeIds.add(server.id);
          publish();
          try {
            await testLatency(server);
          } catch (_) {}
          activeIds.remove(server.id);
          if (!cancellation.isCancelled) completed++;
          publish();
        }
      }

      await Future.wait(
        List.generate(servers.length < 4 ? servers.length : 4, (_) => worker()),
      );
    } finally {
      activeIds.clear();
      if (identical(_batchCancellation, cancellation)) {
        _batchCancellation = null;
      }
      publish(running: false);
    }
  }

  Future<int> replaceSubscription(
    String subscriptionId,
    List<ParsedProxy> proxies,
  ) async => (await replaceSubscriptionSnapshot(subscriptionId, proxies)).count;

  Future<SubscriptionReplacement> replaceSubscriptionSnapshot(
    String subscriptionId,
    List<ParsedProxy> proxies, {
    FreeServerSnapshot? freeSnapshot,
    bool addBuiltInIfMissing = false,
  }) async {
    final source = normalizeSubscriptionUrl(subscriptionId);
    if (source.isEmpty)
      throw ArgumentError.value(subscriptionId, 'subscriptionId');
    if (addBuiltInIfMissing && source != builtInSubscriptionUrl) {
      throw ArgumentError('Only the built-in free feed can be restored');
    }
    // Empty/malformed feeds must not erase working profiles.
    if (proxies.isEmpty) {
      return SubscriptionReplacement(
        count: (await future).where((s) => s.subscriptionId == source).length,
        applied: false,
      );
    }
    var applied = false;
    final updated = await _update(
      (current) async {
        if (source == builtInSubscriptionUrl &&
            ((freeSnapshot != null && freeSnapshot.revision != _freeRevision) ||
                (_freeRemoved && !addBuiltInIfMissing) ||
                (addBuiltInIfMissing &&
                    current.any((s) => s.subscriptionId == source)))) {
          return current;
        }
        final useWorker = _needsProfileWorker(
          current,
          incomingCount: proxies.length,
        );
        var effective = proxies;
        if (source == builtInSubscriptionUrl) {
          final candidates = useWorker
              ? await compute(
                  _distinctSubscriptionProxies,
                  proxies,
                  debugLabel: 'deduplicate-free-profiles',
                )
              : _distinctSubscriptionProxies(proxies);
          // Keep the injected random source and its draw in the serialized
          // mutation; only pure profile data crosses the worker boundary.
          effective = [
            candidates[ref
                .read(builtInFreeRandomProvider)
                .nextInt(candidates.length)],
          ];
        }
        final input = (current: current, proxies: effective, source: source);
        final profiles = useWorker
            ? await compute(
                _buildSubscriptionSnapshot,
                input,
                debugLabel: 'apply-subscription',
              )
            : _buildSubscriptionSnapshot(input);
        applied = true;
        return profiles;
      },
      afterSave: () async {
        if (!applied || source != builtInSubscriptionUrl) return;
        // Clear an opt-out only after an explicit restore saved a valid profile.
        // A crash between writes conservatively leaves the opt-out in force.
        if (addBuiltInIfMissing) await _saveFreeRemoved(false);
        _freeRevision++;
      },
    );
    return SubscriptionReplacement(
      count: updated.where((s) => s.subscriptionId == source).length,
      applied: applied,
    );
  }

  /// Identity parsing, URI construction and model allocation are CPU work. The
  /// caller holds the mutation queue while a large snapshot runs in compute.
  static List<ServerProfileModel> _buildSubscriptionSnapshot(
    _SubscriptionSnapshotInput input,
  ) {
    final current = input.current;
    final source = input.source;
    final previous = current.where((s) => s.subscriptionId == source).toList();
    final byIdentity = <String, ServerProfileModel>{};
    // Prefer the selected/favorite copy when repairing historical duplicates.
    for (final profile in previous.reversed) {
      final identity = _profileIdentity(profile);
      if (identity == null) continue;
      final old = byIdentity[identity];
      if (old == null ||
          profile.isSelected ||
          (!old.isSelected && profile.isFavorite)) {
        byIdentity[identity] = profile;
      }
    }
    final effective = source == builtInSubscriptionUrl
        ? input.proxies
        : subscriptionProxies(source, input.proxies);
    final kept = current.where((s) => s.subscriptionId != source).toList();
    var nextId = _nextId(current);
    final replacements = effective.map((proxy) {
      final old = byIdentity[proxyIdentity(proxy)];
      return _modelFromProxy(proxy, old?.id ?? nextId++, source, previous: old);
    }).toList();
    // When a provider removes the active node, keep selection in that group.
    if (previous.any((s) => s.isSelected) &&
        !replacements.any((s) => s.isSelected) &&
        replacements.isNotEmpty) {
      replacements[0] = replacements[0].copyWith(isSelected: true);
    }
    return [...kept, ...replacements];
  }

  Future<void> deleteBySubscription(String subscriptionId) async {
    final source = normalizeSubscriptionUrl(subscriptionId);
    await _update((current) async {
      if (source == builtInSubscriptionUrl) {
        await _saveFreeRemoved(true);
        _freeRevision++;
      }
      return current.where((s) => s.subscriptionId != source).toList();
    });
  }

  static int _nextId(List<ServerProfileModel> current) => current.isEmpty
      ? DateTime.now().millisecondsSinceEpoch
      : current.map((s) => s.id).reduce((a, b) => a > b ? a : b) + 1;

  static String? _profileIdentity(ServerProfileModel profile) {
    try {
      final raw =
          (jsonDecode(profile.configJson) as Map<String, dynamic>)['rawLink']
              as String;
      return proxyIdentity(_dispatcher.dispatch(raw));
    } catch (_) {
      return null;
    }
  }

  static ServerProfileModel _modelFromProxy(
    ParsedProxy proxy,
    int id,
    String source, {
    ServerProfileModel? previous,
  }) => ServerProfileModel(
    id: id,
    protocol: _protocolTag(proxy),
    name: proxy.displayName,
    host: proxy.host,
    port: proxy.port,
    configJson: jsonEncode({'rawLink': _rawLink(proxy)}),
    subscriptionId: source,
    addedAt: previous?.addedAt ?? DateTime.now(),
    isSelected: previous?.isSelected ?? false,
    isFavorite: previous?.isFavorite ?? false,
    latencyMs: previous?.latencyMs,
  );

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

  static String _endpoint(ParsedProxy p) =>
      '${p.host.contains(':') ? '[${p.host}]' : p.host}:${p.port}';

  static String _rawLink(ParsedProxy p) {
    return switch (p) {
      VlessConfig c => () {
        final params = <String, String>{
          'encryption': c.encryption.isEmpty ? 'none' : c.encryption,
          'security': c.security,
          if (c.sni.isNotEmpty) 'sni': c.sni,
          if (c.fingerprint.isNotEmpty) 'fp': c.fingerprint,
          if (c.alpn.isNotEmpty) 'alpn': c.alpn.join(','),
          if (c.allowInsecure) 'allowInsecure': '1',
          if (c.publicKey.isNotEmpty) 'pbk': c.publicKey,
          if (c.shortId.isNotEmpty) 'sid': c.shortId,
          if (c.spiderX.isNotEmpty) 'spx': c.spiderX,
          'type': c.transport.isEmpty ? 'tcp' : c.transport,
          if (c.path.isNotEmpty) 'path': c.path,
          if (c.transportHost.isNotEmpty) 'host': c.transportHost,
          if (c.grpcServiceName.isNotEmpty) 'serviceName': c.grpcServiceName,
          if (c.flow.isNotEmpty) 'flow': c.flow,
          if (c.xhttpMode.isNotEmpty) 'mode': c.xhttpMode,
          if (c.xPaddingBytes.isNotEmpty) 'xPaddingBytes': c.xPaddingBytes,
        };
        final q = Uri(queryParameters: params).query;
        return 'vless://${Uri.encodeComponent(c.uuid)}@${_endpoint(c)}?$q#${Uri.encodeComponent(c.name)}';
      }(),
      VmessConfig c => () {
        final j = json.encode({
          'v': '2',
          'ps': c.name,
          'add': c.host,
          'port': c.port.toString(),
          'id': c.uuid,
          'aid': c.alterId.toString(),
          'scy': c.security,
          'net': c.network,
          'type': 'none',
          'host': c.wsHost,
          'path': c.path,
          'tls': c.tls,
          'sni': c.sni,
          'alpn': c.alpn,
          'fp': c.fingerprint,
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
        return 'trojan://${c.password}@${_endpoint(c)}?$q#${Uri.encodeComponent(c.name)}';
      }(),
      ShadowsocksConfig c => () {
        final userInfo = base64Encode(utf8.encode('${c.method}:${c.password}'));
        final plug = c.plugin.isNotEmpty
            ? '/?plugin=${Uri.encodeComponent('${c.plugin};${c.pluginOpts}')}'
            : '';
        return 'ss://$userInfo@${_endpoint(c)}$plug#${Uri.encodeComponent(c.name)}';
      }(),
      Hysteria2Config c => () {
        final params = <String, String>{
          if (c.sni.isNotEmpty) 'sni': c.sni,
          if (c.insecure) 'insecure': '1',
          if (c.obfs.isNotEmpty) 'obfs': c.obfs,
          if (c.obfsPassword.isNotEmpty) 'obfs-password': c.obfsPassword,
          if (c.pinSha256.isNotEmpty) 'pinSHA256': c.pinSha256,
          if (c.ports != null && c.ports!.isNotEmpty) 'mport': c.ports!,
          if (c.hopInterval.isNotEmpty) 'hopInterval': c.hopInterval,
        };
        final q = params.isEmpty
            ? ''
            : '?${Uri(queryParameters: params).query}';
        return 'hy2://${Uri.encodeComponent(c.auth)}@${_endpoint(c)}$q#${Uri.encodeComponent(c.name)}';
      }(),
      TuicConfig c => () {
        final params = <String, String>{
          if (c.sni.isNotEmpty) 'sni': c.sni,
          if (c.alpn.isNotEmpty) 'alpn': c.alpn,
          if (c.congestionControl.isNotEmpty)
            'congestion_control': c.congestionControl,
          if (c.udpRelayMode.isNotEmpty) 'udp_relay_mode': c.udpRelayMode,
          if (c.allowInsecure) 'allow_insecure': '1',
        };
        final q = params.isEmpty
            ? ''
            : '?${params.entries.map((e) => "${e.key}=${e.value}").join("&")}';
        return 'tuic://${c.uuid}:${c.password}@${_endpoint(c)}$q#${Uri.encodeComponent(c.name)}';
      }(),
      WireGuardConfig c => () {
        final data = json.encode({
          'privateKey': c.privateKey,
          'publicKey': c.publicKey,
          'presharedKey': c.presharedKey,
          'addresses': c.addresses,
          'dns': c.dns,
          'mtu': c.mtu,
          if (c.reserved != null) 'reserved': c.reserved,
        });
        return 'wireguard://${_endpoint(c)}?config=${Uri.encodeComponent(data)}#${Uri.encodeComponent(c.name)}';
      }(),
      AmneziaWGConfig c => () {
        final data = json.encode({
          'privateKey': c.privateKey,
          'publicKey': c.publicKey,
          'presharedKey': c.presharedKey,
          'addresses': c.addresses,
          'dns': c.dns,
          'mtu': c.mtu,
          if (c.reserved != null) 'reserved': c.reserved,
          'jc': c.jc,
          'jmin': c.jmin,
          'jmax': c.jmax,
          's1': c.s1,
          's2': c.s2,
          's3': c.s3,
          's4': c.s4,
          'h1': c.h1,
          'h2': c.h2,
          'h3': c.h3,
          'h4': c.h4,
        });
        return 'awg://${_endpoint(c)}?config=${Uri.encodeComponent(data)}#${Uri.encodeComponent(c.name)}';
      }(),
      NaiveConfig c =>
        'naive+${c.scheme}://${c.username}:${c.password}@${_endpoint(c)}#${Uri.encodeComponent(c.name)}',
      ShadowTlsConfig c => () {
        final data = json.encode({
          'password': c.password,
          'sni': c.sni,
          'version': c.version,
          'inner': _rawLink(c.innerProxy),
        });
        return 'shadowtls://${_endpoint(c)}?config=${Uri.encodeComponent(data)}#${Uri.encodeComponent(c.name)}';
      }(),
    };
  }
}
