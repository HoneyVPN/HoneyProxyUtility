import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/subscription_model.dart';
import '../../../converter/data/parsers/subscription_parser.dart';
import '../../../servers/presentation/notifiers/servers_notifier.dart';
import '../../../../app/app_theme.dart';

const _subsKey = 'nexproxy_subscriptions';
const _corsBase = '/proxy/?url=';
const _firstRunKey = 'honey_first_run_done';
const _defaultSubUrl = 'https://sub.honeyvpn.ru/ext/5BQLnwsNJ5nvF6dH';

// ── State ────────────────────────────────────────────────────────────────────

class SubscriptionsState {
  final List<SubscriptionModel> subs;
  final Set<int> refreshing; // ids currently being refreshed

  const SubscriptionsState({this.subs = const [], this.refreshing = const {}});

  SubscriptionsState copyWith({List<SubscriptionModel>? subs, Set<int>? refreshing}) =>
      SubscriptionsState(subs: subs ?? this.subs, refreshing: refreshing ?? this.refreshing);

  bool isRefreshing(int id) => refreshing.contains(id);
}

// ── Notifier ─────────────────────────────────────────────────────────────────

final subscriptionsProvider =
    AsyncNotifierProvider<SubscriptionsNotifier, SubscriptionsState>(
  SubscriptionsNotifier.new,
);

class SubscriptionsNotifier extends AsyncNotifier<SubscriptionsState> {
  Timer? _autoTimer;

  @override
  Future<SubscriptionsState> build() async {
    ref.onDispose(() => _autoTimer?.cancel());
    var subs = await _load();

    // Seed HoneyVPN subscription on very first launch
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_firstRunKey) ?? false)) {
      await prefs.setBool(_firstRunKey, true);
      if (subs.isEmpty) {
        final defaultSub = SubscriptionModel(
          id: 1,
          url: _defaultSubUrl,
          name: 'HoneyVPN',
          autoRefresh: true,
          updateIntervalHours: 24,
        );
        subs = [defaultSub];
        await _save(subs);
        _doRefresh(defaultSub);
      }
    }

    _scheduleAutoRefresh();
    for (final s in subs) {
      if (s.needsRefresh) _doRefresh(s);
    }

    // If the default HoneyVPN sub exists but has no servers yet (e.g. first proxy
    // fetch failed), silently re-fetch so users always see servers on load.
    final defaultSub = subs.where((s) => s.url == _defaultSubUrl).firstOrNull;
    if (defaultSub != null) {
      final serverCount = ref.read(serversNotifierProvider).value
          ?.where((sv) => sv.subscriptionId == _defaultSubUrl)
          .length ?? 0;
      if (serverCount == 0) _doRefresh(defaultSub);
    }
    return SubscriptionsState(subs: subs);
  }

  void _scheduleAutoRefresh() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final current = state.value?.subs ?? [];
      for (final s in current) {
        if (s.needsRefresh && !(state.value?.isRefreshing(s.id) ?? false)) {
          _doRefresh(s);
        }
      }
    });
  }

  // ── Persistence ─────────────────────────────────────────────────────────

  Future<List<SubscriptionModel>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_subsKey);
    if (raw == null) return [];
    try {
      return SubscriptionModel.listFromJson(raw);
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<SubscriptionModel> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subsKey, SubscriptionModel.listToJson(list));
  }

  // ── CRUD ─────────────────────────────────────────────────────────────────

  Future<void> add(String url, {String name = ''}) async {
    final current = state.value?.subs ?? [];
    if (current.any((s) => s.url == url)) return;
    final model = SubscriptionModel(
      id: DateTime.now().millisecondsSinceEpoch,
      url: url,
      name: name,
    );
    final updated = [...current, model];
    await _save(updated);
    state = AsyncData((state.value ?? const SubscriptionsState()).copyWith(subs: updated));
    await _doRefresh(model);
  }

  Future<void> delete(int id) async {
    final current = state.value?.subs ?? [];
    final sub = current.firstWhere((s) => s.id == id);
    final updated = current.where((s) => s.id != id).toList();
    await _save(updated);
    state = AsyncData((state.value ?? const SubscriptionsState()).copyWith(subs: updated));
    // Remove servers belonging to this subscription
    await ref.read(serversNotifierProvider.notifier).deleteBySubscription(sub.url);
  }

  Future<void> setInterval(int id, int hours) async {
    final current = state.value?.subs ?? [];
    final updated = current.map((s) => s.id == id ? s.copyWith(updateIntervalHours: hours) : s).toList();
    await _save(updated);
    state = AsyncData((state.value ?? const SubscriptionsState()).copyWith(subs: updated));
    _scheduleAutoRefresh();
  }

  Future<void> register(String url, {String name = '', int serverCount = 0}) async {
    final current = state.value?.subs ?? [];
    if (current.any((s) => s.url == url)) {
      // Already exists — just update server count
      final updated = current.map((s) => s.url == url
          ? s.copyWith(serverCount: serverCount, lastUpdated: DateTime.now())
          : s).toList();
      await _save(updated);
      state = AsyncData((state.value ?? const SubscriptionsState()).copyWith(subs: updated));
      return;
    }
    final model = SubscriptionModel(
      id: DateTime.now().millisecondsSinceEpoch,
      url: url,
      name: name,
      serverCount: serverCount,
      lastUpdated: DateTime.now(),
    );
    final updated = [...current, model];
    await _save(updated);
    state = AsyncData((state.value ?? const SubscriptionsState()).copyWith(subs: updated));
  }

  Future<void> refreshAll() async {
    final subs = state.value?.subs ?? [];
    await Future.wait(subs.map(_doRefresh));
  }

  Future<void> refresh(int id) async {
    final subs = state.value?.subs ?? [];
    final sub = subs.firstWhere((s) => s.id == id);
    await _doRefresh(sub);
  }

  // ── Core refresh logic ────────────────────────────────────────────────────

  Future<void> _doRefresh(SubscriptionModel sub) async {
    final st = state.value ?? const SubscriptionsState();
    if (st.isRefreshing(sub.id)) return;

    state = AsyncData(st.copyWith(refreshing: {...st.refreshing, sub.id}));

    try {
      final fetchUrl = kIsWeb ? '$_corsBase${Uri.encodeComponent(sub.url)}' : sub.url;
      final resp = await Dio().get<String>(
        fetchUrl,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      final body = resp.data ?? '';

      // Parse headers from subscription response
      int? intervalFromHeader;
      final headerInterval = resp.headers.value('profile-update-interval');
      if (headerInterval != null) {
        intervalFromHeader = int.tryParse(headerInterval.trim());
      }

      String? nameFromHeader;
      final headerTitle = resp.headers.value('profile-title');
      if (headerTitle != null) {
        final t = headerTitle.trim();
        if (t.startsWith('base64:')) {
          try {
            nameFromHeader = utf8.decode(base64.decode(t.substring(7)));
          } catch (_) {
            nameFromHeader = t.substring(7);
          }
        } else {
          nameFromHeader = t;
        }
      }

      final proxies = const SubscriptionParser().parse(body);

      await ref.read(serversNotifierProvider.notifier)
          .replaceSubscription(sub.url, proxies);

      final current = state.value?.subs ?? [];
      final updated = current.map((s) {
        if (s.id != sub.id) return s;
        return s.copyWith(
          lastUpdated: DateTime.now(),
          serverCount: proxies.length,
          updateIntervalHours: intervalFromHeader ?? s.updateIntervalHours,
          name: nameFromHeader, // null = keep existing name
        );
      }).toList();
      await _save(updated);

      final newRefreshing = {...(state.value?.refreshing ?? {})}..remove(sub.id);
      state = AsyncData(SubscriptionsState(subs: updated, refreshing: newRefreshing));
    } catch (_) {
      final newRefreshing = {...(state.value?.refreshing ?? {})}..remove(sub.id);
      state = AsyncData((state.value ?? const SubscriptionsState()).copyWith(refreshing: newRefreshing));
      rethrow;
    }
  }
}

// ── Screen ───────────────────────────────────────────────────────────────────

class SubscriptionsScreen extends ConsumerStatefulWidget {
  const SubscriptionsScreen({super.key});
  @override
  ConsumerState<SubscriptionsScreen> createState() => _State();
}

class _State extends ConsumerState<SubscriptionsScreen> {
  final _urlCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  @override
  void dispose() {
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(subscriptionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Subscriptions'),
        actions: [
          if (async.value != null && (async.value!.subs.isNotEmpty))
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh all',
              onPressed: () => ref.read(subscriptionsProvider.notifier).refreshAll(),
            ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showAddDialog,
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (st) => st.subs.isEmpty
            ? _EmptyState(onAdd: _showAddDialog)
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: st.subs.length,
                separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
                itemBuilder: (ctx, i) => _SubTile(
                  sub: st.subs[i],
                  isRefreshing: st.isRefreshing(st.subs[i].id),
                ),
              ),
      ),
    );
  }

  void _showAddDialog() {
    _urlCtrl.clear();
    _nameCtrl.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Subscription'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Name (optional)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(labelText: 'Subscription URL'),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final url = _urlCtrl.text.trim();
              if (url.isEmpty) return;
              Navigator.pop(ctx);
              ref.read(subscriptionsProvider.notifier).add(url, name: _nameCtrl.text.trim());
            },
            child: const Text('Add & Fetch'),
          ),
        ],
      ),
    );
  }
}

// ── Sub tile ──────────────────────────────────────────────────────────────────

class _SubTile extends ConsumerWidget {
  final SubscriptionModel sub;
  final bool isRefreshing;

  const _SubTile({required this.sub, required this.isRefreshing});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final notifier = ref.read(subscriptionsProvider.notifier);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: NexPalette.accent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.cloud_outlined, color: NexPalette.accent, size: 20),
      ),
      title: Text(
        sub.name.isNotEmpty ? sub.name : _host(sub.url),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sub.lastUpdated != null
                ? '${sub.serverCount} servers · ${_ago(sub.lastUpdated!)}'
                : 'Never updated',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          if (sub.updateIntervalHours > 0)
            Text(
              'Auto-update every ${sub.updateIntervalHours}h',
              style: TextStyle(fontSize: 11, color: NexPalette.accent),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Auto-update interval picker
          _IntervalButton(sub: sub),
          const SizedBox(width: 4),
          // Refresh button
          isRefreshing
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: () => notifier.refresh(sub.id),
                  tooltip: 'Refresh',
                ),
          // Delete button
          IconButton(
            icon: Icon(Icons.delete_outline, size: 20, color: cs.error),
            onPressed: () => _confirmDelete(context, ref),
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext ctx, WidgetRef ref) {
    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('Delete subscription?'),
        content: Text('Also removes all ${sub.serverCount} servers from this subscription.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NexColors.error),
            onPressed: () {
              Navigator.pop(c);
              ref.read(subscriptionsProvider.notifier).delete(sub.id);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  static String _host(String url) {
    try { return Uri.parse(url).host; } catch (_) { return url; }
  }

  static String _ago(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

// ── Interval picker button ────────────────────────────────────────────────────

class _IntervalButton extends ConsumerWidget {
  final SubscriptionModel sub;
  const _IntervalButton({required this.sub});

  static const _options = [
    (0, 'Manual'),
    (1, 'Every 1h'),
    (6, 'Every 6h'),
    (12, 'Every 12h'),
    (24, 'Every 24h'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<int>(
      tooltip: 'Auto-update interval',
      initialValue: sub.updateIntervalHours,
      onSelected: (h) => ref.read(subscriptionsProvider.notifier).setInterval(sub.id, h),
      itemBuilder: (_) => _options.map((o) => PopupMenuItem(
        value: o.$1,
        child: Row(
          children: [
            Icon(
              o.$1 == 0 ? Icons.timer_off_outlined : Icons.timer_outlined,
              size: 16,
              color: sub.updateIntervalHours == o.$1 ? NexPalette.accent : cs.onSurface,
            ),
            const SizedBox(width: 8),
            Text(o.$2),
          ],
        ),
      )).toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              sub.updateIntervalHours > 0 ? Icons.timer_outlined : Icons.timer_off_outlined,
              size: 18,
              color: sub.updateIntervalHours > 0 ? NexPalette.accent : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 16, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          const Text('No subscriptions yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('Add a V2Ray, Clash or sing-box subscription URL'),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add Subscription'),
          ),
        ],
      ),
    );
  }
}
