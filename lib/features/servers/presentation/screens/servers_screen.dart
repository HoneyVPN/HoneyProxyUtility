import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/app_theme.dart';
import '../../data/models/server_profile_model.dart';
import '../notifiers/servers_notifier.dart';
import '../widgets/server_list_tile.dart';
import '../widgets/latency_test_action.dart';
import '../../../../app/l10n/strings.dart';
import '../server_selection_groups.dart';
import '../../../subscriptions/data/services/subscription_policy.dart';
import '../../../connection/domain/entities/connection_state.dart';
import '../../../connection/presentation/notifiers/connection_notifier.dart';
import '../../../subscriptions/presentation/screens/subscriptions_screen.dart';
import '../../../subscriptions/presentation/widgets/subscription_refresh_action.dart';

class ServersScreen extends ConsumerStatefulWidget {
  const ServersScreen({super.key});
  @override
  ConsumerState<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends ConsumerState<ServersScreen> {
  final Set<String?> _collapsed = {};

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serversNotifierProvider);
    final subsState = ref.watch(subscriptionsProvider).value;
    final subs = subsState?.subs ?? [];
    final selected = ref.watch(selectedServerProvider);
    final strings = ref.watch(stringsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.serversTitle),
        actions: [
          if (servers.value?.isNotEmpty == true) ...[
            // Refresh all subscriptions
            if (subsState?.subs.isNotEmpty == true)
              const SubscriptionRefreshAction(),
            const LatencyTestAction(),
          ],
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: strings.importServerTooltip,
            onPressed: () => context.push('/converter'),
          ),
        ],
      ),
      body: servers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => Center(child: Text(strings.serversLoadFailed)),
        data: (list) {
          if (list.isEmpty)
            return _EmptyState(onAdd: () => context.push('/converter'));

          final subNames = <String, String>{
            for (final s in subs)
              s.url: s.name.isNotEmpty ? s.name : _hostFromUrl(s.url),
          };

          final groups = serverSelectionGroups(list, subs);

          return ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 80),
            itemCount: groups.length,
            itemBuilder: (ctx, gi) {
              final key = groups[gi].subscriptionId;
              final group = groups[gi].servers;
              final isCollapsed = _collapsed.contains(key);
              final label = key == null
                  ? strings.favoritesTitle
                  : key.isEmpty
                  ? strings.manualGroup
                  : (subNames[key] ?? _hostFromUrl(key));

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _GroupHeader(
                    key: ValueKey(
                      key == null
                          ? 'server-group-favorites'
                          : 'server-group-source-$key',
                    ),
                    label: label,
                    count: group.length,
                    isManual: key?.isEmpty == true,
                    isFavorites: key == null,
                    isCollapsed: isCollapsed,
                    onToggle: () => setState(() {
                      if (isCollapsed)
                        _collapsed.remove(key);
                      else
                        _collapsed.add(key);
                    }),
                    onDeleteGroup: key == null
                        ? null
                        : () => _confirmDeleteGroup(
                            context,
                            ref,
                            label,
                            list
                                .where((server) => server.subscriptionId == key)
                                .toList(),
                            key,
                          ),
                  ),
                  if (!isCollapsed)
                    ...group.map(
                      (s) => ServerListTile(
                        key: ValueKey(s.id),
                        server: s,
                        isSelected: s.id == selected?.id,
                        onTap: () => ref
                            .read(serversNotifierProvider.notifier)
                            .selectServer(s),
                        onDelete: () => _confirmDelete(ctx, ref, s),
                        onTapDetail: () => ctx.push('/servers/${s.id}'),
                      ),
                    ),
                  if (gi < groups.length - 1)
                    Divider(
                      height: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _confirmDeleteGroup(
    BuildContext ctx,
    WidgetRef ref,
    String label,
    List<ServerProfileModel> group,
    String subscriptionId,
  ) {
    final strings = ref.read(stringsProvider);
    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(strings.deleteGroupTitle(label)),
        content: Text(
          strings.deleteGroupContent(group.length, subscriptionId.isNotEmpty),
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
              final active = ref.read(connectionNotifierProvider).activeServer;
              final affectsActive =
                  active != null &&
                  (group.any((server) => server.id == active.id) ||
                      (subscriptionId.isNotEmpty &&
                          active.subscriptionId == subscriptionId));
              if (!await _stopBeforeDelete(affectsActive, strings)) return;
              try {
                if (subscriptionId.isNotEmpty) {
                  // Find and delete via subscription (removes servers + sub entry)
                  final subs =
                      ref.read(subscriptionsProvider).value?.subs ?? [];
                  final sub = subs
                      .where((s) => s.url == subscriptionId)
                      .firstOrNull;
                  if (sub != null) {
                    await ref
                        .read(subscriptionsProvider.notifier)
                        .delete(sub.id);
                    return;
                  }
                }
                // Manual group or subscription not found — delete servers directly
                await ref
                    .read(serversNotifierProvider.notifier)
                    .deleteAll(
                      group.map((s) => s.id).toList(),
                      expectedSubscriptionId: subscriptionId,
                    );
              } catch (_) {
                _showDeleteFailure(strings);
              }
            },
            child: Text(strings.deleteButton),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext ctx, WidgetRef ref, ServerProfileModel s) {
    final strings = ref.read(stringsProvider);
    showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(strings.deleteServerTitle),
        content: Text(
          strings.deleteServerContent(s.name.isNotEmpty ? s.name : s.host),
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
              final active = ref.read(connectionNotifierProvider).activeServer;
              final deletingFreeSlot =
                  normalizeSubscriptionUrl(s.subscriptionId) ==
                  builtInSubscriptionUrl;
              final affectsActive =
                  active != null &&
                  (active.id == s.id ||
                      (deletingFreeSlot &&
                          normalizeSubscriptionUrl(active.subscriptionId) ==
                              builtInSubscriptionUrl));
              if (!await _stopBeforeDelete(affectsActive, strings)) return;
              try {
                await ref
                    .read(serversNotifierProvider.notifier)
                    .delete(s.id, expectedSubscriptionId: s.subscriptionId);
              } catch (_) {
                _showDeleteFailure(strings);
              }
            },
            child: Text(strings.deleteButton),
          ),
        ],
      ),
    );
  }

  // Same acknowledged-stop guard as the Connection screen. Never treat a
  // dismissed confirmation dialog as permission to drop an active session.
  Future<bool> _stopBeforeDelete(bool affectsActive, S strings) async {
    if (!affectsActive) return mounted;
    try {
      await ref.read(connectionNotifierProvider.notifier).disconnect();
    } catch (_) {
      if (!mounted) return false;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.vpnStopFailed)));
      return false;
    }
    if (!mounted) return false;
    if (ref.read(connectionNotifierProvider).status !=
        ConnectionStatus.disconnected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.vpnStopFailed)));
      return false;
    }
    return true;
  }

  void _showDeleteFailure(S strings) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.settingsSaveFailed)));
  }

  static String _hostFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host.isNotEmpty ? uri.host : url;
    } catch (_) {
      return url;
    }
  }
}

// ── Group header ──────────────────────────────────────────────────────────────

class _GroupHeader extends StatelessWidget {
  final String label;
  final int count;
  final bool isManual;
  final bool isFavorites;
  final bool isCollapsed;
  final VoidCallback onToggle;
  final VoidCallback? onDeleteGroup;

  const _GroupHeader({
    super.key,
    required this.label,
    required this.count,
    required this.isManual,
    this.isFavorites = false,
    required this.isCollapsed,
    required this.onToggle,
    required this.onDeleteGroup,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4, top: 8, bottom: 8),
        child: Row(
          children: [
            if (isFavorites)
              Icon(Icons.star_rounded, size: 16, color: cs.primary)
            else
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isManual ? cs.outline : NexPalette.accent,
                ),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  letterSpacing: 0.4,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(
              isCollapsed ? Icons.expand_more : Icons.expand_less,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
            if (onDeleteGroup != null)
              InkWell(
                onTap: onDeleteGroup,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.delete_sweep_outlined,
                    size: 18,
                    color: cs.error.withValues(alpha: 0.6),
                  ),
                ),
              ),
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            strings.noServersYet,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(strings.noServersSubtitle, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: Text(strings.importServerButton),
          ),
        ],
      ),
    );
  }
}
