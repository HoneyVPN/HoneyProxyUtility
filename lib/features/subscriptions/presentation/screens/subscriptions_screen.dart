import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/subscription_model.dart';
import '../widgets/subscription_refresh_action.dart';
import '../../data/services/subscriptions_notifier.dart';
import '../../domain/entities/provider_geo_state.dart';
import '../../../../app/app_theme.dart';
import '../../../../app/l10n/strings.dart';
import '../../../connection/domain/entities/connection_state.dart';
import '../../../connection/presentation/notifiers/connection_notifier.dart';

// Keep existing provider imports source-compatible while separating data/UI.
export '../../data/services/subscriptions_notifier.dart';

class SubscriptionsScreen extends ConsumerStatefulWidget {
  const SubscriptionsScreen({super.key});
  @override
  ConsumerState<SubscriptionsScreen> createState() => _State();
}

class _State extends ConsumerState<SubscriptionsScreen> {
  final _urlCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _scrollController = ScrollController();
  _SubscriptionRowsKey? _rowsKey;
  List<(int, String)>? _activeDragRows;
  List<(int, String)>? _pendingDropRows;
  int? _activeDragIndex;

  void _clearDragCapture() {
    _activeDragRows = null;
    _pendingDropRows = null;
    _activeDragIndex = null;
  }

  @override
  void dispose() {
    _clearDragCapture();
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(subscriptionsProvider);
    final strings = ref.watch(stringsProvider);
    final rowsKey = async.value == null
        ? null
        : _SubscriptionRowsKey(async.value!.subs);
    if (rowsKey != _rowsKey) _clearDragCapture();
    _rowsKey = rowsKey;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.subscriptionsScreenTitle),
        actions: [
          if (async.value != null && (async.value!.subs.isNotEmpty))
            const SubscriptionRefreshAction(),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: strings.addSubscriptionHint,
            onPressed: _showAddDialog,
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          key: const PageStorageKey<String>('subscriptions-list-scroll'),
          constraints: const BoxConstraints(maxWidth: 760),
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) =>
                Center(child: Text(strings.subscriptionsLoadFailed)),
            data: (st) => st.subs.isEmpty
                ? _EmptyState(onAdd: _showAddDialog)
                : ReorderableListView.builder(
                    // A prior asynchronous save can change row indices during
                    // the next drag. Reset that gesture before Flutter renders
                    // its captured child under two keys; metadata-only updates
                    // preserve state and the screen's scroll position persists.
                    key: rowsKey,
                    scrollController: _scrollController,
                    primary: false,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    buildDefaultDragHandles: false,
                    itemCount: st.subs.length,
                    proxyDecorator: (child, index, animation) => Material(
                      color: Theme.of(context).colorScheme.surface,
                      elevation: 3,
                      shadowColor: Colors.black.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      child: child,
                    ),
                    onReorderStart: (index) {
                      if (!mounted || rowsKey != _rowsKey) return;
                      _clearDragCapture();
                      if (index < 0 || index >= st.subs.length) return;
                      _activeDragRows = List.unmodifiable(
                        st.subs.map((sub) => (sub.id, sub.url)),
                      );
                      _activeDragIndex = index;
                    },
                    onReorderEnd: (index) {
                      if (!mounted || rowsKey != _rowsKey) return;
                      // End is emitted before the drop animation; the later
                      // onReorder must still refer to the rows at drag start.
                      // A stationary drop emits no onReorder, so retain none.
                      _pendingDropRows = index == _activeDragIndex
                          ? null
                          : _activeDragRows;
                      _activeDragRows = null;
                      _activeDragIndex = null;
                    },
                    onReorder: (oldIndex, newIndex) async {
                      if (!mounted || rowsKey != _rowsKey) return;
                      final rows =
                          _pendingDropRows ??
                          st.subs.map((sub) => (sub.id, sub.url)).toList();
                      _clearDragCapture();
                      if (oldIndex < 0 ||
                          oldIndex >= rows.length ||
                          newIndex < 0 ||
                          newIndex > rows.length)
                        return;
                      if (newIndex > oldIndex) newIndex--;
                      final reordered = List.of(rows);
                      final moved = reordered.removeAt(oldIndex);
                      reordered.insert(newIndex, moved);
                      try {
                        await ref
                            .read(subscriptionsProvider.notifier)
                            .move(
                              moved.$1,
                              expectedUrl: moved.$2,
                              beforeId: newIndex + 1 < reordered.length
                                  ? reordered[newIndex + 1].$1
                                  : null,
                              expectedBeforeUrl: newIndex + 1 < reordered.length
                                  ? reordered[newIndex + 1].$2
                                  : null,
                            );
                      } catch (_) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              strings.locale == 'ru'
                                  ? 'Не удалось сохранить порядок подписок'
                                  : 'Could not save subscription order',
                            ),
                          ),
                        );
                      }
                    },
                    itemBuilder: (ctx, i) => _SubTile(
                      key: ValueKey('subscription-${st.subs[i].id}'),
                      index: i,
                      canReorder: st.subs.length > 1,
                      sub: st.subs[i],
                      failure: st.failures[st.subs[i].id],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  void _showAddDialog() {
    final strings = ref.read(stringsProvider);
    final ru = strings.locale == 'ru';
    _urlCtrl.clear();
    _nameCtrl.clear();
    var saving = false;
    String? saveError;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateDialog) => AlertDialog(
          title: Text(strings.addSubscriptionHint),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                enabled: !saving,
                decoration: InputDecoration(
                  labelText: ru
                      ? 'Название (необязательно)'
                      : 'Name (optional)',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _urlCtrl,
                enabled: !saving,
                decoration: InputDecoration(
                  labelText: ru ? 'Ссылка подписки' : 'Subscription URL',
                  errorText: saveError,
                ),
                keyboardType: TextInputType.url,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(strings.cancelButton),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final url = _urlCtrl.text.trim();
                      if (url.isEmpty) return;
                      final name = _nameCtrl.text.trim();
                      updateDialog(() {
                        saving = true;
                        saveError = null;
                      });
                      try {
                        await ref
                            .read(subscriptionsProvider.notifier)
                            .add(url, name: name);
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (_) {
                        if (!ctx.mounted) return;
                        updateDialog(() {
                          saving = false;
                          saveError = strings.settingsSaveFailed;
                        });
                      }
                    },
              child: Text(saving ? strings.savingSettings : strings.addButton),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionRowsKey extends LocalKey {
  _SubscriptionRowsKey(List<SubscriptionModel> subscriptions)
    : _rows = List.unmodifiable(
        subscriptions.map(
          (subscription) => (subscription.id, subscription.url),
        ),
      );

  final List<(int, String)> _rows;

  @override
  bool operator ==(Object other) {
    if (other is! _SubscriptionRowsKey || _rows.length != other._rows.length) {
      return false;
    }
    for (var index = 0; index < _rows.length; index++) {
      if (_rows[index] != other._rows[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_rows);
}

// ── Sub tile ──────────────────────────────────────────────────────────────────

class _SubTile extends ConsumerWidget {
  final SubscriptionModel sub;
  final int index;
  final bool canReorder;
  final SubscriptionFailure? failure;

  const _SubTile({
    super.key,
    required this.sub,
    required this.index,
    required this.canReorder,
    this.failure,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final strings = ref.watch(stringsProvider);
    final ru = strings.locale == 'ru';
    final serverCount = ref.watch(subscriptionServerCountProvider(sub.url));
    final geoWarning = switch (sub.providerGeoStatus) {
      ProviderGeoStatus.stale ||
      ProviderGeoStatus.unavailable => strings.providerGeoWarning(
        sub.providerGeoIssue,
        hasLastGood: sub.providerGeo != null,
      ),
      _ => null,
    };

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: canReorder
          ? ReorderableDragStartListener(
              key: ValueKey('reorder-subscription-${sub.id}'),
              index: index,
              child: Tooltip(
                message: ru ? 'Изменить порядок' : 'Reorder',
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: SizedBox(
                    width: 32,
                    height: 44,
                    child: Icon(
                      Icons.drag_handle_rounded,
                      size: 20,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            )
          : Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.cloud_outlined,
                color: cs.onSurfaceVariant,
                size: 18,
              ),
            ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              sub.name.isNotEmpty ? sub.name : _host(sub.url),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (failure != null || geoWarning != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: failure != null
                  ? strings.subscriptionRefreshFailureTooltip
                  : geoWarning!,
              child: Icon(
                Icons.warning_rounded,
                size: 14,
                color: NexColors.warningFor(cs.brightness),
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sub.lastUpdated != null
                ? '${_countLabel(serverCount, ru)} · ${_ago(sub.lastUpdated!, ru)}'
                : (ru ? 'Ещё не обновлялась' : 'Never updated'),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          if (sub.updateIntervalHours > 0)
            Text(
              ru
                  ? 'Каждые ${sub.updateIntervalHours} ч'
                  : 'Every ${sub.updateIntervalHours}h',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
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
          SubscriptionRefreshAction(subscriptionId: sub.id, size: 20),
          // Delete button
          IconButton(
            icon: Icon(Icons.delete_outline, size: 20, color: cs.error),
            onPressed: () => _confirmDelete(context, ref),
            tooltip: strings.deleteButton,
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext ctx, WidgetRef ref) {
    final serverCount = ref.read(subscriptionServerCountProvider(sub.url));
    final strings = ref.read(stringsProvider);
    final ru = strings.locale == 'ru';
    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(ru ? 'Удалить подписку?' : 'Delete subscription?'),
        content: Text(
          ru
              ? 'Также будут удалены все серверы этой подписки: $serverCount.'
              : 'Also removes all $serverCount servers from this subscription.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(strings.cancelButton),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NexColors.error),
            onPressed: () async {
              Navigator.pop(c);
              final connection = ref.read(connectionNotifierProvider);
              if (connection.activeServer?.subscriptionId == sub.url) {
                try {
                  await ref
                      .read(connectionNotifierProvider.notifier)
                      .disconnect();
                } catch (_) {
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(strings.vpnStopFailed)),
                  );
                  return;
                }
                if (!ctx.mounted) return;
                if (ref.read(connectionNotifierProvider).status !=
                    ConnectionStatus.disconnected) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(strings.vpnStopFailed)),
                  );
                  return;
                }
              }
              if (!ctx.mounted) return;
              try {
                await ref.read(subscriptionsProvider.notifier).delete(sub.id);
              } catch (_) {
                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(strings.settingsSaveFailed)),
                );
              }
            },
            child: Text(strings.deleteButton),
          ),
        ],
      ),
    );
  }

  static String _host(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  static String _ago(DateTime d, bool ru) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return ru ? 'только что' : 'just now';
    if (diff.inMinutes < 60)
      return ru ? '${diff.inMinutes} мин назад' : '${diff.inMinutes}m ago';
    if (diff.inHours < 24)
      return ru ? '${diff.inHours} ч назад' : '${diff.inHours}h ago';
    return ru ? '${diff.inDays} дн назад' : '${diff.inDays}d ago';
  }

  static String _countLabel(int count, bool ru) {
    if (!ru) return '$count server${count == 1 ? '' : 's'}';
    final lastTwo = count % 100;
    if (lastTwo >= 11 && lastTwo <= 14) return '$count серверов';
    return switch (count % 10) {
      1 => '$count сервер',
      2 || 3 || 4 => '$count сервера',
      _ => '$count серверов',
    };
  }
}

// ── Interval picker button ────────────────────────────────────────────────────

class _IntervalButton extends ConsumerWidget {
  final SubscriptionModel sub;
  const _IntervalButton({required this.sub});

  static const _options = [0, 1, 6, 12, 24];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final strings = ref.watch(stringsProvider);
    final ru = strings.locale == 'ru';
    return PopupMenuButton<int>(
      tooltip: ru ? 'Период обновления' : 'Auto-update interval',
      initialValue: sub.updateIntervalHours,
      onSelected: (h) async {
        try {
          await ref.read(subscriptionsProvider.notifier).setInterval(sub.id, h);
        } catch (_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(strings.settingsSaveFailed)));
        }
      },
      itemBuilder: (_) =>
          ({..._options, sub.updateIntervalHours}.toList()..sort())
              .map(
                (o) => PopupMenuItem(
                  height: MediaQuery.sizeOf(context).width >= 700 ? 34 : 44,
                  value: o,
                  child: Row(
                    children: [
                      Icon(
                        o == 0
                            ? Icons.timer_off_outlined
                            : Icons.timer_outlined,
                        size: 16,
                        color: sub.updateIntervalHours == o
                            ? NexPalette.accent
                            : cs.onSurface,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        o == 0
                            ? (ru ? 'Вручную' : 'Manual')
                            : (ru ? 'Каждые $o ч' : 'Every ${o}h'),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              sub.updateIntervalHours > 0
                  ? Icons.timer_outlined
                  : Icons.timer_off_outlined,
              size: 18,
              color: sub.updateIntervalHours > 0
                  ? NexPalette.accent
                  : cs.onSurfaceVariant,
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

class _EmptyState extends ConsumerWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    final ru = strings.locale == 'ru';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 32,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            ru ? 'Подписок пока нет' : 'No subscriptions yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            ru
                ? 'Добавьте ссылку от VPN-сервиса.'
                : 'Add a link from your VPN provider.',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: Text(strings.addSubscriptionHint),
          ),
        ],
      ),
    );
  }
}
