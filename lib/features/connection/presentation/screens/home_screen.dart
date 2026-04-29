import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../app/app_theme.dart';
import '../../../../app/l10n/strings.dart';
import '../../domain/entities/connection_state.dart';
import '../notifiers/connection_notifier.dart';
import '../widgets/connect_button.dart';
import '../widgets/speed_stats_bar.dart';
import '../../../servers/data/models/server_profile_model.dart';
import '../../../servers/presentation/notifiers/servers_notifier.dart';
import '../../../servers/presentation/widgets/server_list_tile.dart';
import '../../../subscriptions/presentation/screens/subscriptions_screen.dart';

const _defaultSubUrl = 'https://sub.honeyvpn.ru/ext/5BQLnwsNJ5nvF6dH';
const _upgradeUrl = 'https://t.me/honeyvpnru_bot';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final Set<String> _collapsed = {};
  bool _testingAll = false;

  @override
  Widget build(BuildContext context) {
    final conn    = ref.watch(connectionNotifierProvider);
    final selected = ref.watch(selectedServerProvider);
    final servers  = ref.watch(serversNotifierProvider);
    final subsState = ref.watch(subscriptionsProvider).value;
    final subs = subsState?.subs ?? [];
    final s = ref.watch(stringsProvider);

    final subNames = <String, String>{
      for (final sub in subs)
        sub.url: sub.name.isNotEmpty ? sub.name : _hostFromUrl(sub.url),
    };

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── App bar ───────────────────────────────────────────────────────
          SliverAppBar(
            title: const Text('Honey'),
            floating: true,
            snap: true,
            actions: [
              if (subsState?.subs.isNotEmpty == true)
                IconButton(
                  icon: const Icon(Icons.subscriptions_outlined, size: 20),
                  tooltip: s.subscriptionsTooltip,
                  onPressed: () => context.push('/subscriptions'),
                ),
              if (servers.value?.isNotEmpty == true && subsState?.subs.isNotEmpty == true)
                IconButton(
                  icon: const Icon(Icons.sync_rounded, size: 20),
                  tooltip: s.refreshSubsTooltip,
                  onPressed: () => ref.read(subscriptionsProvider.notifier).refreshAll(),
                ),
              if (servers.value?.isNotEmpty == true)
                _testingAll
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(
                        icon: const Icon(Icons.network_ping_outlined, size: 20),
                        tooltip: s.pingAllTooltip,
                        onPressed: _testAll,
                      ),
              IconButton(
                icon: const Icon(Icons.add_rounded, size: 22),
                tooltip: s.importServerTooltip,
                onPressed: () => context.push('/converter'),
              ),
              IconButton(
                icon: const Icon(Icons.tune_outlined, size: 20),
                onPressed: () => context.push('/settings'),
              ),
              const SizedBox(width: 4),
            ],
          ),

          // ── Hero: connect section ─────────────────────────────────────────
          SliverToBoxAdapter(
            child: _HeroSection(
              conn: conn,
              selected: selected,
              s: s,
              onConnectTap: () => _handleConnectTap(ref, conn, selected),
            ),
          ),

          // ── Speed stats ───────────────────────────────────────────────────
          if (conn.isConnected)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: SpeedStatsBar(stats: conn.stats),
              ),
            ),

          // ── Error banner ──────────────────────────────────────────────────
          if (conn.status == ConnectionStatus.error && conn.errorMessage != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _ErrorBanner(message: conn.errorMessage!),
              ),
            ),

          // ── Server list ───────────────────────────────────────────────────
          servers.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => SliverFillRemaining(
              child: Center(child: Text('Error: $e')),
            ),
            data: (list) {
              if (list.isEmpty) {
                return SliverFillRemaining(
                  child: _EmptyState(s: s, onAdd: () => context.push('/converter')),
                );
              }

              final groups = <String, List<ServerProfileModel>>{};
              for (final sv in list) {
                (groups[sv.subscriptionId] ??= []).add(sv);
              }
              final keys = groups.keys.toList()
                ..sort((a, b) {
                  if (a.isEmpty) return -1;
                  if (b.isEmpty) return 1;
                  return a.compareTo(b);
                });

              final items = <Widget>[];
              for (int gi = 0; gi < keys.length; gi++) {
                final key   = keys[gi];
                final group = groups[key]!;
                final isCollapsed = _collapsed.contains(key);
                final label = key.isEmpty ? s.manualGroup : (subNames[key] ?? _hostFromUrl(key));

                items.add(_GroupHeader(
                  label: label,
                  count: group.length,
                  isManual: key.isEmpty,
                  isCollapsed: isCollapsed,
                  onToggle: () => setState(() {
                    if (isCollapsed) _collapsed.remove(key); else _collapsed.add(key);
                  }),
                  onDeleteGroup: () => _confirmDeleteGroup(context, ref, label, group, key, s),
                ));

                if (!isCollapsed) {
                  for (final sv in group) {
                    items.add(ServerListTile(
                      server: sv,
                      isSelected: sv.id == selected?.id,
                      onTap: () => ref.read(serversNotifierProvider.notifier).selectServer(sv),
                      onDelete: () => _confirmDelete(context, ref, sv, s),
                      onTapDetail: () => context.push('/servers/${sv.id}'),
                    ));
                  }
                  if (key == _defaultSubUrl || key.contains("honeyvpn.ru")) items.add(const _UpgradeBanner());
                }

                if (gi < keys.length - 1) {
                  items.add(Divider(
                    height: 1, indent: 16, endIndent: 16,
                    color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
                  ));
                }
              }

              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => i == items.length ? const SizedBox(height: 100) : items[i],
                  childCount: items.length + 1,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void _handleConnectTap(WidgetRef ref, NexConnectionState conn, ServerProfileModel? server) {
    if (conn.isBusy) return;
    if (conn.isConnected) {
      ref.read(connectionNotifierProvider.notifier).disconnect();
    } else {
      if (server == null) return;
      ref.read(connectionNotifierProvider.notifier).connect(server);
    }
  }

  Future<void> _testAll() async {
    setState(() => _testingAll = true);
    await ref.read(serversNotifierProvider.notifier).testAllLatency();
    if (mounted) setState(() => _testingAll = false);
  }

  void _confirmDeleteGroup(BuildContext ctx, WidgetRef ref, String label,
      List<ServerProfileModel> group, String subscriptionId, S s) {
    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(s.deleteGroupTitle(label)),
        content: Text(s.deleteGroupContent(group.length, subscriptionId.isNotEmpty)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(s.cancelButton)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NexColors.error),
            onPressed: () {
              Navigator.pop(c);
              if (subscriptionId.isNotEmpty) {
                final allSubs = ref.read(subscriptionsProvider).value?.subs ?? [];
                final sub = allSubs.where((sub) => sub.url == subscriptionId).firstOrNull;
                if (sub != null) {
                  ref.read(subscriptionsProvider.notifier).delete(sub.id);
                  return;
                }
              }
              for (final sv in group) {
                ref.read(serversNotifierProvider.notifier).delete(sv.id);
              }
            },
            child: Text(s.deleteButton),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext ctx, WidgetRef ref, ServerProfileModel sv, S s) {
    showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(s.deleteServerTitle),
        content: Text(s.deleteServerContent(sv.name.isNotEmpty ? sv.name : sv.host)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(s.cancelButton)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NexColors.error),
            onPressed: () {
              Navigator.pop(c);
              ref.read(serversNotifierProvider.notifier).delete(sv.id);
            },
            child: Text(s.deleteButton),
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

// ── Hero connect section ──────────────────────────────────────────────────────

class _HeroSection extends StatelessWidget {
  final NexConnectionState conn;
  final ServerProfileModel? selected;
  final S s;
  final VoidCallback onConnectTap;

  const _HeroSection({
    required this.conn,
    required this.selected,
    required this.s,
    required this.onConnectTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final statusColor = switch (conn.status) {
      ConnectionStatus.connected    => NexColors.connected,
      ConnectionStatus.connecting
      || ConnectionStatus.preparing => NexColors.connecting,
      ConnectionStatus.error        => NexColors.error,
      _                             => cs.onSurfaceVariant.withOpacity(0.4),
    };

    final statusLabel = switch (conn.status) {
      ConnectionStatus.connected     => s.statusConnected,
      ConnectionStatus.connecting    => s.statusConnecting,
      ConnectionStatus.preparing     => s.statusPreparing,
      ConnectionStatus.disconnecting => s.statusDisconnecting,
      ConnectionStatus.error         => s.statusError,
      _                              => s.statusDisconnected,
    };

    final serverLabel = selected != null
        ? (selected!.name.isNotEmpty ? selected!.name : selected!.host)
        : s.noServerSelected;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        children: [
          // Status pill
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.10),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                    boxShadow: conn.isConnected
                        ? [BoxShadow(color: statusColor.withOpacity(0.6), blurRadius: 6)]
                        : null,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Connect button
          ConnectButton(status: conn.status, onTap: onConnectTap),

          const SizedBox(height: 20),

          // Server name
          Text(
            serverLabel,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: cs.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
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
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
        child: Row(
          children: [
            Container(
              width: 6, height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isManual ? cs.outline : NexPalette.accent,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  letterSpacing: 0.6,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              isCollapsed ? Icons.expand_more_rounded : Icons.expand_less_rounded,
              size: 18,
              color: cs.onSurfaceVariant.withOpacity(0.6),
            ),
            InkWell(
              onTap: onDeleteGroup,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(Icons.delete_sweep_outlined, size: 16, color: cs.error.withOpacity(0.45)),
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
  final S s;
  final VoidCallback onAdd;
  const _EmptyState({required this.s, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.power_settings_new_rounded, size: 52, color: cs.outline.withOpacity(0.5)),
          const SizedBox(height: 20),
          Text(s.noServersYet, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            s.noServersSubtitle,
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(s.importServerButton),
          ),
        ],
      ),
    );
  }
}

// ── Upgrade banner ───────────────────────────────────────────────────────────

class _UpgradeBanner extends StatelessWidget {
  const _UpgradeBanner();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const gold = Color(0xFFFFB300);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: InkWell(
        onTap: () => launchUrl(Uri.parse(_upgradeUrl), mode: LaunchMode.externalApplication),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [gold.withOpacity(0.13), gold.withOpacity(0.04)],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: gold.withOpacity(0.28)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: gold.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.bolt_rounded, color: gold, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Hysteria2 — в 3× быстрее',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: gold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Личный сервер · без ограничений · без логов',
                      style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.55)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Купить →',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: gold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Error banner ──────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: NexColors.error.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexColors.error.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: NexColors.error, size: 17),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: const TextStyle(color: NexColors.error, fontSize: 12))),
        ],
      ),
    );
  }
}
