import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/app_theme.dart';
import '../../data/models/server_profile_model.dart';
import '../notifiers/servers_notifier.dart';
import '../widgets/server_list_tile.dart';
import '../../../subscriptions/presentation/screens/subscriptions_screen.dart';

class ServersScreen extends ConsumerStatefulWidget {
  const ServersScreen({super.key});
  @override
  ConsumerState<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends ConsumerState<ServersScreen> {
  final Set<String> _collapsed = {};
  bool _testingAll = false;

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serversNotifierProvider);
    final subsState = ref.watch(subscriptionsProvider).value;
    final subs = subsState?.subs ?? [];
    final selected = ref.watch(selectedServerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Servers'),
        actions: [
          if (servers.value?.isNotEmpty == true) ...[
            // Refresh all subscriptions
            if (subsState?.subs.isNotEmpty == true)
              IconButton(
                icon: const Icon(Icons.sync),
                tooltip: 'Refresh subscriptions',
                onPressed: () => ref.read(subscriptionsProvider.notifier).refreshAll(),
              ),
            // Test all latency
            _testingAll
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.network_ping),
                    tooltip: 'Test all latency',
                    onPressed: _testAll,
                  ),
          ],
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/converter'),
          ),
        ],
      ),
      body: servers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) {
          if (list.isEmpty) return _EmptyState(onAdd: () => context.push('/converter'));

          final subNames = <String, String>{
            for (final s in subs) s.url: s.name.isNotEmpty ? s.name : _hostFromUrl(s.url),
          };

          final groups = <String, List<ServerProfileModel>>{};
          for (final s in list) {
            (groups[s.subscriptionId] ??= []).add(s);
          }

          final keys = groups.keys.toList()
            ..sort((a, b) {
              if (a.isEmpty) return -1;
              if (b.isEmpty) return 1;
              return a.compareTo(b);
            });

          return ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 80),
            itemCount: keys.length,
            itemBuilder: (ctx, gi) {
              final key = keys[gi];
              final group = groups[key]!;
              final isCollapsed = _collapsed.contains(key);
              final label = key.isEmpty ? 'Manual' : (subNames[key] ?? _hostFromUrl(key));

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _GroupHeader(
                    label: label,
                    count: group.length,
                    isManual: key.isEmpty,
                    isCollapsed: isCollapsed,
                    onToggle: () => setState(() {
                      if (isCollapsed) _collapsed.remove(key); else _collapsed.add(key);
                    }),
                    onDeleteGroup: () => _confirmDeleteGroup(context, ref, label, group, key),
                  ),
                  if (!isCollapsed)
                    ...group.map((s) => ServerListTile(
                      server: s,
                      isSelected: s.id == selected?.id,
                      onTap: () => ref.read(serversNotifierProvider.notifier).selectServer(s),
                      onDelete: () => _confirmDelete(ctx, ref, s),
                      onTapDetail: () => ctx.push('/servers/${s.id}'),
                    )),
                  if (gi < keys.length - 1)
                    Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _confirmDeleteGroup(BuildContext ctx, WidgetRef ref, String label,
      List<ServerProfileModel> group, String subscriptionId) {
    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text('Delete "$label"?'),
        content: Text('Remove all ${group.length} servers'
            '${subscriptionId.isNotEmpty ? ' and unsubscribe' : ''}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NexColors.error),
            onPressed: () {
              Navigator.pop(c);
              if (subscriptionId.isNotEmpty) {
                // Find and delete via subscription (removes servers + sub entry)
                final subs = ref.read(subscriptionsProvider).value?.subs ?? [];
                final sub = subs.where((s) => s.url == subscriptionId).firstOrNull;
                if (sub != null) {
                  ref.read(subscriptionsProvider.notifier).delete(sub.id);
                  return;
                }
              }
              // Manual group or subscription not found — delete servers directly
              ref.read(serversNotifierProvider.notifier).deleteAll(group.map((s) => s.id).toList());
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _testAll() async {
    setState(() => _testingAll = true);
    await ref.read(serversNotifierProvider.notifier).testAllLatency();
    if (mounted) setState(() => _testingAll = false);
  }

  void _confirmDelete(BuildContext ctx, WidgetRef ref, ServerProfileModel s) {
    showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('Delete server?'),
        content: Text('Remove "${s.name.isNotEmpty ? s.name : s.host}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NexColors.error),
            onPressed: () {
              Navigator.pop(c);
              ref.read(serversNotifierProvider.notifier).delete(s.id);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
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
  final bool isCollapsed;
  final VoidCallback onToggle;
  final VoidCallback onDeleteGroup;

  const _GroupHeader({
    required this.label,
    required this.count,
    required this.isManual,
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
            Container(
              width: 8, height: 8,
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
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, fontWeight: FontWeight.w500),
              ),
            ),
            Icon(
              isCollapsed ? Icons.expand_more : Icons.expand_less,
              size: 18,
              color: cs.onSurfaceVariant,
            ),
            InkWell(
              onTap: onDeleteGroup,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.delete_sweep_outlined, size: 18, color: cs.error.withOpacity(0.6)),
              ),
            ),
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
          Icon(Icons.dns_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          const Text('No servers yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('Import a proxy link or subscription URL', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Import Server'),
          ),
        ],
      ),
    );
  }
}
