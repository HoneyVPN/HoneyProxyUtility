import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/subscription_model.dart';
import '../../../converter/data/parsers/base_parser.dart';
import '../../../converter/data/parsers/subscription_response_parser.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../servers/presentation/notifiers/servers_notifier.dart';
import 'subscription_policy.dart';
import 'subscription_order.dart';
import '../../domain/entities/free_server_snapshot.dart';
import '../../domain/entities/provider_routing_metadata.dart';
import '../../domain/entities/provider_geo_state.dart';
import '../../../connection/data/singbox/provider_geo_runtime.dart';
import '../../../connection/data/singbox/provider_geo_bundle.dart';

final _log = Logger('SubscriptionsNotifier');
const _subsKey = 'nexproxy_subscriptions';
const _corsBase = '/proxy/?url=';

/// Injectable transport also allows subscription tests to run without network.
final subscriptionDioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );
  ref.onDispose(() => dio.close(force: true));
  return dio;
});

final subscriptionResponseParserProvider = Provider<SubscriptionResponseParser>(
  (ref) => const SubscriptionResponseParser(),
);

enum SubscriptionFailure {
  unsupportedConfiguration,
  invalidResponse,
  updateFailed,
}

class SubscriptionsState {
  final List<SubscriptionModel> subs;
  final Set<int> refreshing;
  final Map<int, SubscriptionFailure> failures;

  const SubscriptionsState({
    this.subs = const [],
    this.refreshing = const {},
    this.failures = const {},
  });

  SubscriptionsState copyWith({
    List<SubscriptionModel>? subs,
    Set<int>? refreshing,
    Map<int, SubscriptionFailure>? failures,
  }) => SubscriptionsState(
    subs: subs ?? this.subs,
    refreshing: refreshing ?? this.refreshing,
    failures: failures ?? this.failures,
  );

  bool isRefreshing(int id) => refreshing.contains(id);
}

final subscriptionsProvider =
    AsyncNotifierProvider<SubscriptionsNotifier, SubscriptionsState>(
      SubscriptionsNotifier.new,
    );

final subscriptionServerCountProvider = Provider.family<int, String>((
  ref,
  url,
) {
  final servers = ref.watch(serversNotifierProvider).value ?? [];
  return servers
      .where((s) => s.subscriptionId == normalizeSubscriptionUrl(url))
      .length;
});

class SubscriptionsNotifier extends AsyncNotifier<SubscriptionsState> {
  Timer? _autoTimer;
  final _refreshes = <(int, int), Future<void>>{};
  final _cancellations = <(int, int), CancelToken>{};
  final _generations = <int, int>{};
  final _forceGeoRefreshes = <(int, int)>{};
  Future<void> _pendingMutation = Future<void>.value();
  Future<void>? _freeAddition;

  @override
  Future<SubscriptionsState> build() async {
    ref.onDispose(() {
      _autoTimer?.cancel();
      for (final token in _cancellations.values) {
        token.cancel('Subscription notifier disposed');
      }
    });
    var subs = await _load();
    if (!subs.any((s) => s.url == builtInSubscriptionUrl)) {
      subs = [
        SubscriptionModel(
          id: _nextId(subs),
          url: builtInSubscriptionUrl,
          name: 'HoneyVPN',
          updateIntervalHours: 24,
        ),
        ...subs,
      ];
    }
    // Count stored profiles, including the offline repair of legacy free feeds.
    final servers = await ref.read(serversNotifierProvider.future);
    subs = subs
        .map(
          (s) => s.copyWith(
            serverCount: servers.where((p) => p.subscriptionId == s.url).length,
          ),
        )
        .toList();
    await _save(subs);
    _scheduleAutoRefresh();
    // Defer refresh until build's AsyncData is published. Refreshing inside
    // build used to erase its in-flight flag and allow a second request.
    unawaited(
      Future<void>.delayed(Duration.zero, () async {
        if (!ref.mounted) return;
        final current = state.value?.subs ?? [];
        await Future.wait(current.where((s) => s.needsRefresh).map(_doRefresh));
      }),
    );
    return SubscriptionsState(subs: subs);
  }

  void _scheduleAutoRefresh() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      for (final sub in state.value?.subs ?? <SubscriptionModel>[]) {
        if (sub.needsRefresh) unawaited(_doRefresh(sub));
      }
    });
  }

  Future<List<SubscriptionModel>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_subsKey);
    if (raw == null) return [];
    try {
      final byUrl = <String, SubscriptionModel>{};
      for (final sub in SubscriptionModel.listFromJson(raw)) {
        final url = normalizeSubscriptionUrl(sub.url);
        if (url.isEmpty) continue;
        byUrl.putIfAbsent(
          url,
          () => SubscriptionModel(
            id: sub.id,
            url: url,
            name: sub.name,
            lastUpdated: sub.lastUpdated,
            serverCount: sub.serverCount,
            updateIntervalHours: sub.updateIntervalHours,
            updateIntervalOverridden: sub.updateIntervalOverridden,
            providerRouting: sub.providerRouting,
            providerGeo: sub.providerGeo,
            providerGeoStatus: sub.providerGeoStatus,
            providerGeoIssue: sub.providerGeoIssue,
          ),
        );
      }
      return byUrl.values.toList();
    } catch (e) {
      _log.warning('Failed to load subscriptions from storage', e);
      return [];
    }
  }

  Future<void> _save(List<SubscriptionModel> list) async {
    final encoded =
        list.length >= 16 ||
            list.any((subscription) => subscription.providerRouting != null)
        ? await compute(
            SubscriptionModel.listToJson,
            list,
            debugLabel: 'save-subscriptions',
          )
        : SubscriptionModel.listToJson(list);
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_subsKey);
    try {
      if (!await prefs.setString(_subsKey, encoded)) {
        throw StateError('Failed to save subscriptions');
      }
    } catch (error, stack) {
      // Keep a failed order/interval/metadata write out of preference caches.
      // A single key-only restoration is best effort, never a disk guarantee.
      try {
        if (previous == null) {
          await prefs.remove(_subsKey);
        } else {
          await prefs.setString(_subsKey, previous);
        }
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<List<SubscriptionModel>> _update(
    List<SubscriptionModel> Function(List<SubscriptionModel>) transform,
  ) {
    final operation = _pendingMutation.then((_) async {
      await future;
      final updated = transform(state.requireValue.subs);
      await _save(updated);
      if (ref.mounted) {
        final ids = updated.map((sub) => sub.id).toSet();
        state = AsyncData(
          state.requireValue.copyWith(
            subs: updated,
            failures: Map.of(state.requireValue.failures)
              ..removeWhere((id, _) => !ids.contains(id)),
          ),
        );
      }
      return updated;
    });
    _pendingMutation = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> add(String url, {String name = ''}) async {
    url = normalizeSubscriptionUrl(url);
    if (url.isEmpty) return;
    if (url == builtInSubscriptionUrl) {
      await addBuiltInFreeServer();
      return;
    }
    final updated = await _update(
      (current) => current.any((s) => s.url == url)
          ? current
          : [
              ...current,
              SubscriptionModel(id: _nextId(current), url: url, name: name),
            ],
    );
    await _doRefresh(updated.firstWhere((s) => s.url == url));
  }

  Future<void> move(
    int id, {
    required String expectedUrl,
    int? beforeId,
    String? expectedBeforeUrl,
  }) async {
    await _update(
      (current) => moveSubscription(
        current,
        id,
        expectedUrl: expectedUrl,
        beforeId: beforeId,
        expectedBeforeUrl: expectedBeforeUrl,
      ),
    );
  }

  /// Explicit opt-in from the catalog. A normal refresh/import never restores
  /// a removed free profile, and repeated catalog taps join this operation.
  Future<void> addBuiltInFreeServer() {
    final pending = _freeAddition;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _addBuiltInFreeServer().whenComplete(() {
      if (identical(_freeAddition, operation)) _freeAddition = null;
    });
    _freeAddition = operation;
    return operation;
  }

  Future<void> _addBuiltInFreeServer() async {
    await future;
    final snapshot = await ref
        .read(serversNotifierProvider.notifier)
        .freeServerSnapshot();
    if (snapshot.present) return;
    final updated = await _update(
      (current) => current.any((s) => s.url == builtInSubscriptionUrl)
          ? current
          : [
              SubscriptionModel(
                id: _nextId(current),
                url: builtInSubscriptionUrl,
                name: 'HoneyVPN',
                updateIntervalHours: 24,
              ),
              ...current,
            ],
    );
    final sub = updated.firstWhere((s) => s.url == builtInSubscriptionUrl);
    // Retire an automatic request before starting the explicit restore. Its
    // response must not rotate the newly restored profile after this finishes.
    _cancellations[(sub.id, _generations[sub.id] ?? 0)]?.cancel(
      'Explicit free server restore',
    );
    _generations[sub.id] = (_generations[sub.id] ?? 0) + 1;
    await _doRefresh(
      sub,
      restoreBuiltIn: true,
      freeSnapshot: snapshot,
      rethrowFailure: true,
    );
  }

  Future<void> delete(int id) async {
    await future;
    final sub = state.requireValue.subs.where((s) => s.id == id).firstOrNull;
    if (sub == null) return;
    _cancellations[(id, _generations[id] ?? 0)]?.cancel('Subscription removed');
    _generations[id] = (_generations[id] ?? 0) + 1;
    if (sub.url == builtInSubscriptionUrl) {
      // Persist free opt-out before removing the subscription metadata. A crash
      // between writes must not leave a profile eligible for automatic return.
      await ref
          .read(serversNotifierProvider.notifier)
          .deleteBySubscription(sub.url);
      await _update((current) => current.where((s) => s.id != id).toList());
      await _retireProviderCache();
      return;
    }
    await _update((current) => current.where((s) => s.id != id).toList());
    await ref
        .read(serversNotifierProvider.notifier)
        .deleteBySubscription(sub.url);
    await _retireProviderCache();
  }

  Future<void> _retireProviderCache() async {
    // Deletion is already durable. Maintenance may preserve files when fresh
    // references cannot be enumerated; it must not undo the user's deletion.
    try {
      await ref.read(providerGeoRuntimeProvider).collectGarbage();
    } catch (_) {
      /* A future successful refresh can retry bounded retirement. */
    }
  }

  Future<void> setInterval(int id, int hours) async {
    await _update(
      (current) => current
          .map(
            (s) => s.id == id
                ? s.copyWith(
                    updateIntervalHours: hours,
                    updateIntervalOverridden: true,
                  )
                : s,
          )
          .toList(),
    );
  }

  /// Compatibility entry point for callers that have already imported profiles.
  /// The visible count is derived from stored profiles, never the remote feed.
  Future<void> register(
    String url, {
    String name = '',
    int serverCount = 0,
  }) async {
    url = normalizeSubscriptionUrl(url);
    if (url.isEmpty) return;
    final profiles = await ref.read(serversNotifierProvider.future);
    final count = profiles.where((s) => s.subscriptionId == url).length;
    await _update((current) {
      if (current.any((s) => s.url == url)) {
        return current
            .map(
              (s) => s.url == url
                  ? s.copyWith(serverCount: count, lastUpdated: DateTime.now())
                  : s,
            )
            .toList();
      }
      return [
        ...current,
        SubscriptionModel(
          id: _nextId(current),
          url: url,
          name: name,
          serverCount: count,
          lastUpdated: DateTime.now(),
        ),
      ];
    });
  }

  Future<int> importProxies(String url, List<ParsedProxy> proxies) async {
    url = normalizeSubscriptionUrl(url);
    final servers = ref.read(serversNotifierProvider.notifier);
    final freeSnapshot = url == builtInSubscriptionUrl
        ? await servers.freeServerSnapshot()
        : null;
    final replacement = await servers.replaceSubscriptionSnapshot(
      url,
      proxies,
      freeSnapshot: freeSnapshot,
    );
    if (replacement.applied)
      await register(url, serverCount: replacement.count);
    return replacement.count;
  }

  Future<void> refreshAll() async {
    await future;
    await Future.wait(
      List<SubscriptionModel>.of(
        state.requireValue.subs,
      ).map((sub) => _doRefresh(sub, forceGeo: true)),
    );
  }

  Future<void> refresh(int id) async {
    await future;
    final sub = state.requireValue.subs.where((s) => s.id == id).firstOrNull;
    if (sub != null) await _doRefresh(sub, forceGeo: true);
  }

  Future<void> _doRefresh(
    SubscriptionModel sub, {
    bool restoreBuiltIn = false,
    FreeServerSnapshot? freeSnapshot,
    bool rethrowFailure = false,
    bool forceGeo = false,
  }) {
    final generation = _generations[sub.id] ?? 0;
    final key = (sub.id, generation);
    if (forceGeo) _forceGeoRefreshes.add(key);
    final pending = _refreshes[key];
    if (pending != null) return pending;
    late final Future<void> operation;
    // Set the lock before publishing the refreshing flag to listeners.
    operation =
        Future<void>(
          () => _performRefresh(
            sub,
            generation,
            restoreBuiltIn: restoreBuiltIn,
            freeSnapshot: freeSnapshot,
            rethrowFailure: rethrowFailure,
          ),
        ).whenComplete(() {
          if (_refreshes[key] == operation) {
            _refreshes.remove(key);
            // A manual request upgrades this refresh only. Later automatic
            // refreshes must still respect the healthy DAT cache interval.
            _forceGeoRefreshes.remove(key);
          }
        });
    _refreshes[key] = operation;
    return operation;
  }

  bool _contains(SubscriptionModel sub) =>
      ref.mounted &&
      (state.value?.subs.any((s) => s.id == sub.id && s.url == sub.url) ??
          false);

  Future<void> _performRefresh(
    SubscriptionModel sub,
    int generation, {
    bool restoreBuiltIn = false,
    FreeServerSnapshot? freeSnapshot,
    bool rethrowFailure = false,
  }) async {
    bool current() =>
        _contains(sub) && (_generations[sub.id] ?? 0) == generation;
    if (!current()) return;
    if (sub.url == builtInSubscriptionUrl) {
      freeSnapshot ??= await ref
          .read(serversNotifierProvider.notifier)
          .freeServerSnapshot();
      if (!current() || (freeSnapshot.removed && !restoreBuiltIn)) return;
    }
    final key = (sub.id, generation);
    final token = CancelToken();
    _cancellations[key] = token;
    state = AsyncData(
      state.requireValue.copyWith(
        refreshing: {...state.requireValue.refreshing, sub.id},
        failures: {...state.requireValue.failures}..remove(sub.id),
      ),
    );
    try {
      final fetchUrl = kIsWeb
          ? '$_corsBase${Uri.encodeComponent(sub.url)}'
          : sub.url;
      final resp = await ref
          .read(subscriptionDioProvider)
          .get<String>(
            fetchUrl,
            cancelToken: token,
            options: Options(responseType: ResponseType.plain),
          );
      if (token.isCancelled || !current()) return;
      final parsed = await ref
          .read(subscriptionResponseParserProvider)
          .parse(
            subscriptionId: sub.id,
            body: resp.data ?? '',
            headers: resp.headers.map,
          );
      // Parsing now yields to another isolate. Deletion/re-import may retire
      // this response while it runs, before any server replacement is allowed.
      if (token.isCancelled || !current()) return;
      final replacement = await ref
          .read(serversNotifierProvider.notifier)
          .replaceSubscriptionSnapshot(
            sub.url,
            parsed.proxies,
            freeSnapshot: freeSnapshot,
            addBuiltInIfMissing: restoreBuiltIn,
          );
      if (token.isCancelled || !current() || !replacement.applied) return;
      // Dependent geo publication leases the newly applied free slot, not the
      // old pre-replacement snapshot (whose revision was deliberately retired).
      final geoLease = sub.url == builtInSubscriptionUrl
          ? await ref
                .read(serversNotifierProvider.notifier)
                .freeServerSnapshot()
          : null;
      final interval = _providerInterval(resp.headers.map);
      final title = _profileTitle(
        _singleHeader(resp.headers.map, 'profile-title'),
      );
      await _update(
        (currentSubs) => !current()
            ? currentSubs
            : currentSubs
                  .map(
                    (s) => s.id == sub.id
                        ? s.copyWith(
                            lastUpdated: DateTime.now(),
                            serverCount: replacement.count,
                            name: title,
                            updateIntervalHours:
                                !s.updateIntervalOverridden && interval != null
                                ? interval
                                : s.updateIntervalHours,
                          )
                        : s,
                  )
                  .toList(),
      );
      if (current() && !token.isCancelled) {
        await _publishProviderRouting(
          sub,
          generation,
          token,
          envelope: parsed.envelope,
          parseFailed: parsed.routingParseFailed,
          routingDeclared: parsed.routingDeclared,
          freeLease: geoLease,
          forceGeo: _forceGeoRefreshes.contains(key),
        );
      }
    } catch (e) {
      if (current() && !token.isCancelled) {
        state = AsyncData(
          state.requireValue.copyWith(
            failures: {
              ...state.requireValue.failures,
              sub.id: e is UnsupportedConfigurationException
                  ? SubscriptionFailure.unsupportedConfiguration
                  : e is ParseException
                  ? SubscriptionFailure.invalidResponse
                  : SubscriptionFailure.updateFailed,
            },
          ),
        );
      }
      if (e is! DioException || !CancelToken.isCancel(e)) {
        // Subscription URLs may contain access tokens; do not put them in logs.
        _log.warning(
          'Failed to refresh subscription ${sub.id}: ${e.runtimeType}',
        );
      }
      if (rethrowFailure && current() && !token.isCancelled) rethrow;
    } finally {
      _cancellations.remove(key);
      if (ref.mounted) {
        state = AsyncData(
          state.requireValue.copyWith(
            refreshing: {...state.requireValue.refreshing}
              ..removeWhere(
                (id) =>
                    id == sub.id &&
                    !_cancellations.keys.any((active) => active.$1 == id),
              ),
          ),
        );
      }
    }
  }

  /// HTTP-preview imports retain provider headers without fetching the feed a
  /// second time or changing the user's selected proxy import subset.
  Future<void> adoptProviderResponse(
    String url,
    String body,
    Map<String, List<String>> headers,
  ) async {
    await future;
    url = normalizeSubscriptionUrl(url);
    final sub = state.requireValue.subs
        .where((row) => row.url == url)
        .firstOrNull;
    if (sub == null) return;
    final servers = ref.read(serversNotifierProvider.notifier);
    final lease = url == builtInSubscriptionUrl
        ? await servers.freeServerSnapshot()
        : null;
    if (lease != null && (lease.removed || !lease.present)) return;
    final oldGeneration = _generations[sub.id] ?? 0;
    _cancellations[(sub.id, oldGeneration)]?.cancel(
      'Imported subscription response',
    );
    final generation = oldGeneration + 1;
    _generations[sub.id] = generation;
    final token = CancelToken();
    final key = (sub.id, generation);
    _cancellations[key] = token;
    try {
      final parsed = await ref
          .read(subscriptionResponseParserProvider)
          .parse(
            subscriptionId: sub.id,
            body: body,
            headers: headers,
            includeProxies: false,
          );
      await _publishProviderRouting(
        sub,
        generation,
        token,
        envelope: parsed.envelope,
        parseFailed: parsed.routingParseFailed,
        routingDeclared: parsed.routingDeclared,
        freeLease: lease,
        responseHeaders: headers,
        forceGeo: true,
      );
    } finally {
      _cancellations.remove(key);
    }
  }

  Future<void> _publishProviderRouting(
    SubscriptionModel sub,
    int generation,
    CancelToken token, {
    ProviderRoutingEnvelope? envelope,
    bool parseFailed = false,
    bool routingDeclared = false,
    FreeServerSnapshot? freeLease,
    bool forceGeo = false,
    Map<String, List<String>> responseHeaders = const {},
  }) async {
    bool current() =>
        ref.mounted &&
        !token.isCancelled &&
        _contains(sub) &&
        (_generations[sub.id] ?? 0) == generation &&
        (freeLease == null ||
            ref
                .read(serversNotifierProvider.notifier)
                .isCurrentFreeServerSnapshot(freeLease));
    if (!current()) return;
    // First HTTP import adopts provider cadence/name even with no geo header.
    if (responseHeaders.isNotEmpty) {
      final interval = _providerInterval(responseHeaders);
      final title = _profileTitle(
        _singleHeader(responseHeaders, 'profile-title'),
      );
      await _update(
        (rows) => !current()
            ? rows
            : rows
                  .map(
                    (row) => row.id == sub.id && row.url == sub.url
                        ? row.copyWith(
                            name: title,
                            updateIntervalHours:
                                !row.updateIntervalOverridden &&
                                    interval != null
                                ? interval
                                : row.updateIntervalHours,
                          )
                        : row,
                  )
                  .toList(),
      );
    }
    if (parseFailed) {
      final latest = state.requireValue.subs
          .where((row) => row.id == sub.id && row.url == sub.url)
          .firstOrNull;
      if (!routingDeclared &&
          latest?.providerRouting == null &&
          latest?.providerGeo == null)
        return;
      await _update(
        (rows) => !current()
            ? rows
            : rows
                  .map(
                    (row) => row.id == sub.id
                        ? row.copyWith(
                            providerGeoIssue: ProviderGeoIssue.invalid,
                            providerGeoStatus: row.providerGeo == null
                                ? ProviderGeoStatus.unavailable
                                : ProviderGeoStatus.stale,
                          )
                        : row,
                  )
                  .toList(),
      );
      return;
    }
    ProviderRoutingMetadata? metadata;
    ProviderGeoReference? previous;
    var retryGeo = false;
    await _update((rows) {
      if (!current()) return rows;
      return rows.map((row) {
        if (row.id != sub.id || row.url != sub.url) return row;
        // Absence differs from explicit routing/off. Do not erase previously
        // declared rules when an otherwise valid feed omits optional metadata.
        metadata = envelope?.metadata.commands.isNotEmpty == true
            ? envelope!.metadata
            : row.providerRouting;
        previous = row.providerGeo;
        retryGeo =
            row.providerGeoStatus == ProviderGeoStatus.stale ||
            row.providerGeoStatus == ProviderGeoStatus.unavailable;
        if (metadata == null) return row;
        final off = ProviderGeoRuntime.activeProfile(metadata!) == null;
        return row.copyWith(
          providerRouting: metadata,
          providerGeoStatus: off
              ? ProviderGeoStatus.off
              : ProviderGeoStatus.updating,
          clearProviderGeoIssue: true,
        );
      }).toList();
    });
    if (!current() ||
        metadata == null ||
        ProviderGeoRuntime.activeProfile(metadata!) == null)
      return;
    final desiredDigest = providerMetadataDigest(metadata!);
    ProviderGeoPrepared? prepared;
    try {
      prepared = await ref
          .read(providerGeoRuntimeProvider)
          .prepare(
            metadata!,
            subscriptionUrl: sub.url,
            previous: previous,
            forceRefresh: forceGeo || retryGeo,
            cancelToken: token,
          );
      if (!current()) return;
      await _update(
        (rows) => !current()
            ? rows
            : rows
                  .map(
                    (row) =>
                        row.id == sub.id &&
                            row.url == sub.url &&
                            row.providerRouting != null &&
                            providerMetadataDigest(row.providerRouting!) ==
                                desiredDigest
                        ? row.copyWith(
                            providerGeo: prepared!.reference,
                            providerGeoStatus: ProviderGeoStatus.ready,
                            clearProviderGeoIssue: true,
                          )
                        : row,
                  )
                  .toList(),
      );
    } catch (error) {
      if (!current()) return;
      await _update(
        (rows) => !current()
            ? rows
            : rows
                  .map(
                    (row) =>
                        row.id == sub.id &&
                            row.url == sub.url &&
                            row.providerRouting != null &&
                            providerMetadataDigest(row.providerRouting!) ==
                                desiredDigest
                        ? row.copyWith(
                            providerGeoIssue: error is ProviderGeoException
                                ? error.issue
                                : ProviderGeoIssue.invalid,
                            providerGeoStatus: row.providerGeo == null
                                ? ProviderGeoStatus.unavailable
                                : ProviderGeoStatus.stale,
                          )
                        : row,
                  )
                  .toList(),
      );
    } finally {
      // The immutable bundle remains pinned until its reference is persisted,
      // or until a retired/deleted subscription rejects this publication.
      await prepared?.release();
    }
  }

  static String? _singleHeader(Map<String, List<String>> headers, String name) {
    final rows = headers.entries
        .where((entry) => entry.key.toLowerCase() == name)
        .toList();
    return rows.length == 1 && rows.single.value.length == 1
        ? rows.single.value.single
        : null;
  }

  static int? _providerInterval(Map<String, List<String>> headers) {
    final value = int.tryParse(
      _singleHeader(headers, 'profile-update-interval')?.trim() ?? '',
    );
    return value != null && value >= 1 && value <= 168 ? value : null;
  }

  static String? _profileTitle(String? header) {
    final title = header?.trim();
    if (title == null || title.isEmpty || utf8.encode(title).length > 2048)
      return null;
    if (!title.startsWith('base64:')) return _safeTitle(title);
    try {
      return _safeTitle(
        utf8.decode(base64.decode(base64.normalize(title.substring(7)))),
      );
    } catch (_) {
      return null;
    }
  }

  static String? _safeTitle(String title) =>
      title.isNotEmpty &&
          utf8.encode(title).length <= 512 &&
          !RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(title)
      ? title
      : null;

  static int _nextId(List<SubscriptionModel> current) => current.isEmpty
      ? 1
      : current.map((s) => s.id).reduce((a, b) => a > b ? a : b) + 1;
}
