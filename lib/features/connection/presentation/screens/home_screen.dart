import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
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
import '../../../update/update_provider.dart';
import '../../../settings/presentation/notifiers/settings_notifier.dart';
import '../../../settings/data/models/app_settings.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final Set<String> _collapsed = {};
  bool _testingAll = false;
  bool _updateDismissed = false;

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionNotifierProvider);
    final selected = ref.watch(selectedServerProvider);
    final servers = ref.watch(serversNotifierProvider);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final subsState = ref.watch(subscriptionsProvider).value;
    final subs = subsState?.subs ?? [];
    final s = ref.watch(stringsProvider);
    final update = ref.watch(updateProvider).value;

    final subNames = <String, String>{
      for (final sub in subs) sub.url: sub.name.isNotEmpty ? sub.name : _hostFromUrl(sub.url),
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Honey'),
        actions: [
          if (subsState?.subs.isNotEmpty == true)
            IconButton(
              icon: const Icon(Icons.subscriptions_outlined),
              tooltip: s.subscriptionsTooltip,
              onPressed: () => context.push('/subscriptions'),
            ),
          if (servers.value?.isNotEmpty == true) ...[
            if (subsState?.subs.isNotEmpty == true)
              IconButton(
                icon: const Icon(Icons.sync),
                tooltip: s.refreshSubsTooltip,
                onPressed: () => ref.read(subscriptionsProvider.notifier).refreshAll(),
              ),
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
                    tooltip: s.pingAllTooltip,
                    onPressed: _testAll,
                  ),
          ],
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: s.importServerTooltip,
            onPressed: () => context.push('/converter'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Fixed: status / connect card
          _StatusCard(
            conn: conn,
            selected: selected,
            s: s,
            onConnectTap: () => _handleConnectTap(ref, conn, selected),
            connectionMode: settings.connectionMode,
            onModeChanged: ref.read(settingsProvider.notifier).setConnectionMode,
          ),

          // Fixed: speed stats when connected
          if (conn.isConnected)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SpeedStatsBar(stats: conn.stats),
            ),

          // Fixed: error banner
          if (conn.status == ConnectionStatus.error && conn.errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _ErrorBanner(message: conn.errorMessage!),
            ),

                    // Fixed: update banner
          if (!_updateDismissed && update != null && update.hasUpdate)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _UpdateBanner(
                info: update,
                onDismiss: () => setState(() => _updateDismissed = true),
              ),
            ),

          // Scrollable: server list
          Expanded(
            child: servers.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (list) {
                if (list.isEmpty) {
                  return _EmptyState(s: s, onAdd: () => context.push('/converter'));
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
                  final key = keys[gi];
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
                        onTap: () {
                          ref.read(serversNotifierProvider.notifier).selectServer(sv);
                          if (conn.isConnected) {
                            ref.read(connectionNotifierProvider.notifier).connect(sv);
                          }
                        },
                        onDelete: () => _confirmDelete(context, ref, sv, s),
                        onTapDetail: () => context.push('/servers/${sv.id}'),
                      ));
                    }
                  }

                  // Hysteria promo under built-in subscription
                  if (key.contains('sub.honeyvpn.ru') && subs.length == 1) {
                    items.add(_HysteriaBanner(
                      onTap: () => context.push('/marketplace/honeyvpn'),
                    ));
                  }

                  if (gi < keys.length - 1) {
                    items.add(Divider(
                      height: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ));
                  }
                }

                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: items.length,
                  itemBuilder: (_, i) => items[i],
                );
              },
            ),
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
                final subs = ref.read(subscriptionsProvider).value?.subs ?? [];
                final sub = subs.where((sub) => sub.url == subscriptionId).firstOrNull;
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

// ── Status / Connect card ─────────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final NexConnectionState conn;
  final ServerProfileModel? selected;
  final S s;
  final VoidCallback onConnectTap;
  final ConnectionMode connectionMode;
  final ValueChanged<ConnectionMode> onModeChanged;

  const _StatusCard({
    required this.conn,
    required this.selected,
    required this.s,
    required this.onConnectTap,
    required this.connectionMode,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final statusColor = switch (conn.status) {
      ConnectionStatus.connected => NexColors.connected,
      ConnectionStatus.connecting || ConnectionStatus.preparing => NexColors.connecting,
      ConnectionStatus.error => NexColors.error,
      _ => NexColors.disconnected,
    };
    final statusLabel = switch (conn.status) {
      ConnectionStatus.connected     => s.statusConnected,
      ConnectionStatus.connecting    => s.statusConnecting,
      ConnectionStatus.preparing     => s.statusPreparing,
      ConnectionStatus.disconnecting => s.statusDisconnecting,
      ConnectionStatus.error         => s.statusError,
      _                              => s.statusDisconnected,
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: statusColor.withOpacity(conn.isConnected ? 0.4 : 0.15),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: statusColor.withOpacity(conn.isConnected ? 0.07 : 0.02),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor.withOpacity(0.10),
              border: Border.all(color: statusColor.withOpacity(0.45), width: 1.5),
              boxShadow: conn.isConnected ? [
                BoxShadow(
                  color: statusColor.withOpacity(0.25),
                  blurRadius: 14,
                  spreadRadius: 2,
                ),
              ] : null,
            ),
            child: Icon(
              conn.isConnected ? Icons.shield : Icons.shield_outlined,
              color: statusColor,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusLabel,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: statusColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  selected != null
                      ? (selected!.name.isNotEmpty ? selected!.name : selected!.host)
                      : s.noServerSelected,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ConnectButton(status: conn.status, onTap: onConnectTap),
        ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _ModeButton(
                  label: 'TUN',
                  icon: Icons.vpn_lock_outlined,
                  selected: connectionMode == ConnectionMode.tunnel,
                  onTap: () => onModeChanged(ConnectionMode.tunnel),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ModeButton(
                  label: 'Proxy',
                  icon: Icons.device_hub_outlined,
                  selected: connectionMode == ConnectionMode.proxy,
                  onTap: () => onModeChanged(ConnectionMode.proxy),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Mode button ──────────────────────────────────────────────────────────────

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _ModeButton({required this.label, required this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: selected ? NexPalette.accent.withOpacity(0.12) : cs.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? NexPalette.accent.withOpacity(0.5) : cs.outlineVariant.withOpacity(0.4),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: selected ? NexPalette.accent : cs.onSurfaceVariant),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? NexPalette.accent : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Group header ───────────────────────────────────────────────────────────────

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
              width: 7, height: 7,
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
                  fontSize: 12,
                  letterSpacing: 0.3,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$count',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontWeight: FontWeight.w500),
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
                child: Icon(Icons.delete_sweep_outlined, size: 17, color: cs.error.withOpacity(0.55)),
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
          Icon(Icons.shield_outlined, size: 56, color: cs.outline),
          const SizedBox(height: 16),
          Text(s.noServersYet, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            s.noServersSubtitle,
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: Text(s.importServerButton),
          ),
        ],
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NexColors.error.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexColors.error.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: NexColors.error, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: const TextStyle(color: NexColors.error, fontSize: 13))),
        ],
      ),
    );
  }
}

class _UpdateBanner extends StatefulWidget {
  final UpdateInfo info;
  final VoidCallback onDismiss;
  const _UpdateBanner({required this.info, required this.onDismiss});

  @override
  State<_UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<_UpdateBanner> {
  double? _progress;

  Future<void> _install() async {
    if (!Platform.isAndroid) {
      await launchUrl(Uri.parse(widget.info.downloadUrl), mode: LaunchMode.externalApplication);
      return;
    }
    setState(() => _progress = 0);
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/update.apk';
      await Dio().download(
        widget.info.downloadUrl,
        path,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _progress = received / total);
          }
        },
      );
      await OpenFile.open(path);
    } catch (_) {
      await launchUrl(Uri.parse(widget.info.downloadUrl), mode: LaunchMode.externalApplication);
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: NexPalette.accent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexPalette.accent.withOpacity(0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update_outlined, color: NexPalette.accent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Доступна версия ${widget.info.remoteVersion}',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: NexPalette.accent),
                    ),
                    Text(
                      'Установлена ${widget.info.currentVersion}',
                      style: TextStyle(fontSize: 11, color: NexPalette.accent.withOpacity(0.7)),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: _progress != null ? null : _install,
                style: TextButton.styleFrom(
                  foregroundColor: NexPalette.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _progress != null ? '${(_progress! * 100).toInt()}%' : 'Обновить',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: widget.onDismiss,
                child: Icon(Icons.close, size: 16, color: NexPalette.accent.withOpacity(0.6)),
              ),
            ],
          ),
          if (_progress != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress,
                backgroundColor: NexPalette.accent.withOpacity(0.15),
                color: NexPalette.accent,
                minHeight: 3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Hysteria promo banner ─────────────────────────────────────────────────────

class _HysteriaBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _HysteriaBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              NexPalette.accent.withOpacity(0.14),
              NexColors.connecting.withOpacity(0.08),
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: NexPalette.accent.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NexPalette.accent.withOpacity(0.15),
              ),
              child: const Icon(Icons.bolt_rounded, color: NexPalette.accent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Hysteria 2 — быстрее в разы',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: NexPalette.accent),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Подключите скоростные серверы',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 13, color: NexPalette.accentDark),
          ],
        ),
      ),
    );
  }
}
