import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';

import 'package:dio/dio.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../app/flavor.dart';
import '../../../../app/app_theme.dart';
import '../../../../app/l10n/strings.dart';
import '../../data/vpn_disclosure_provider.dart';
import '../../domain/entities/connection_state.dart';
import '../notifiers/connection_notifier.dart';
import '../widgets/connect_button.dart';
import '../widgets/speed_stats_bar.dart';
import '../widgets/server_selector_chip.dart';
import '../../../servers/data/models/server_profile_model.dart';
import '../../../servers/presentation/notifiers/servers_notifier.dart';
import '../../../servers/presentation/widgets/server_list_tile.dart';
import '../../../servers/presentation/widgets/country_presentation.dart';
import '../../../servers/presentation/widgets/server_connection_label.dart';
import '../../../servers/presentation/widgets/latency_badge.dart';
import '../../../servers/presentation/widgets/latency_test_action.dart';
import '../../../servers/presentation/server_selection_groups.dart';
import '../../../subscriptions/presentation/widgets/subscription_refresh_action.dart';
import '../../../subscriptions/data/services/subscriptions_notifier.dart';
import '../../../subscriptions/data/services/subscription_policy.dart';
import '../../../subscriptions/domain/entities/provider_geo_state.dart';
import '../../../update/update_provider.dart';
import '../../../settings/presentation/notifiers/settings_notifier.dart';
import '../../../settings/presentation/widgets/settings_save_feedback.dart';
import '../../../settings/data/models/app_settings.dart';
import '../../../diagnostics/presentation/diagnostic_send_sheet.dart';

class ToggleConnectionIntent extends Intent {
  const ToggleConnectionIntent();
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final Set<String?> _collapsed = {};
  bool _updateDismissed = false;

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionNotifierProvider);
    final selected = ref.watch(selectedServerProvider);
    final servers = ref.watch(serversNotifierProvider);
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final subsState = ref.watch(subscriptionsProvider).value;
    final subs = subsState?.subs ?? [];
    final failedSubscriptionUrls = {
      for (final sub in subs)
        if (subsState?.failures.containsKey(sub.id) ?? false) sub.url,
    };
    final s = ref.watch(stringsProvider);
    final geoWarnings = {
      for (final sub in subs)
        if (sub.providerGeoStatus == ProviderGeoStatus.stale ||
            sub.providerGeoStatus == ProviderGeoStatus.unavailable)
          sub.url: s.providerGeoWarning(
            sub.providerGeoIssue,
            hasLastGood: sub.providerGeo != null,
          ),
    };
    final update = ref.watch(updateProvider).value;
    // Eagerly load disclosure state so .value is ready before user taps connect
    ref.watch(vpnDisclosureProvider);

    final subNames = <String, String>{
      for (final sub in subs)
        sub.url: sub.name.isNotEmpty ? sub.name : _hostFromUrl(sub.url),
    };

    final serverCount = servers.value?.length ?? 0;
    final ru = s.locale == 'ru';
    final compactControls =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        MediaQuery.sizeOf(context).height < 480 &&
        MediaQuery.textScalerOf(context).scale(14) > 21;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter, meta: true):
            ToggleConnectionIntent(),
        SingleActivator(LogicalKeyboardKey.enter, control: true):
            ToggleConnectionIntent(),
      },
      child: Actions(
        actions: {
          ToggleConnectionIntent: CallbackAction<ToggleConnectionIntent>(
            onInvoke: (_) {
              _handleConnectTap(ref, conn, selected);
              return null;
            },
          ),
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(s.homeTitle),
            actions: [
              IconButton(
                icon: const Icon(Icons.layers_outlined, size: 19),
                tooltip: s.subscriptionsTooltip,
                onPressed: () => context.push('/subscriptions'),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: IconButton(
                  icon: const Icon(Icons.add_rounded),
                  tooltip: s.importServerTooltip,
                  onPressed: () => context.push('/converter'),
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        compactControls ? 4 : 12,
                        16,
                        compactControls ? 4 : 12,
                      ),
                      child: _ConnectionControls(
                        conn: conn,
                        selected: selected,
                        s: s,
                        compact: compactControls,
                        onConnectTap: () =>
                            _handleConnectTap(ref, conn, selected),
                        onServerTap: _showServerChooser,
                      ),
                    ),
                    if (!kIsWeb &&
                        defaultTargetPlatform == TargetPlatform.windows)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: Center(
                          child: _ConnectionModeControl(
                            conn: conn,
                            s: s,
                            connectionMode: settings.connectionMode,
                            onModeChanged: (mode) => saveSettingsWithFeedback(
                              context,
                              () => ref
                                  .read(settingsProvider.notifier)
                                  .setConnectionMode(mode),
                              s.settingsSaveFailed,
                            ),
                          ),
                        ),
                      ),
                    if (conn.isConnected)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          compactControls ? 4 : 8,
                        ),
                        child: SpeedStatsBar(stats: conn.stats),
                      ),
                    Expanded(
                      child: CustomScrollView(
                        slivers: [
                          if (conn.status == ConnectionStatus.error &&
                              conn.errorMessage != null)
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                              sliver: SliverToBoxAdapter(
                                child: _ErrorBanner(
                                  message: conn.errorMessage!,
                                ),
                              ),
                            ),
                          if (!_updateDismissed &&
                              update != null &&
                              update.hasUpdate)
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                              sliver: SliverToBoxAdapter(
                                child: _UpdateBanner(
                                  info: update,
                                  onDismiss: () =>
                                      setState(() => _updateDismissed = true),
                                ),
                              ),
                            ),
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(24, 12, 16, 2),
                            sliver: SliverToBoxAdapter(
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      s.serversTitle,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (serverCount > 0)
                                    const LatencyTestAction(),
                                  if (subs.isNotEmpty)
                                    const SubscriptionRefreshAction(),
                                ],
                              ),
                            ),
                          ),
                          servers.when(
                            loading: () => const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.all(40),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            ),
                            error: (e, _) => SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: _ErrorBanner(
                                  message: s.serversLoadFailed,
                                ),
                              ),
                            ),
                            data: (all) {
                              final list = all;
                              if (list.isEmpty) {
                                return SliverToBoxAdapter(
                                  child: _EmptyState(
                                    s: s,
                                    onAdd: () => context.push('/converter'),
                                  ),
                                );
                              }
                              final groups = serverSelectionGroups(list, subs);
                              final items = <Widget>[];
                              for (final section in groups) {
                                final key = section.subscriptionId;
                                final group = section.servers;
                                final isCollapsed = _collapsed.contains(key);
                                final label = key == null
                                    ? s.favoritesTitle
                                    : key.isEmpty
                                    ? s.manualGroup
                                    : (subNames[key] ?? _hostFromUrl(key));
                                items.add(
                                  Material(
                                    color: Colors.transparent,
                                    clipBehavior: Clip.antiAlias,
                                    child: _GroupHeader(
                                      key: ValueKey(
                                        key == null
                                            ? 'server-group-favorites'
                                            : 'server-group-source-$key',
                                      ),
                                      label: label,
                                      hasRefreshFailure: failedSubscriptionUrls
                                          .contains(key),
                                      geoWarning: geoWarnings[key],
                                      count: group.length,
                                      isManual: key?.isEmpty == true,
                                      isFavorites: key == null,
                                      isCollapsed: isCollapsed,
                                      onToggle: () => setState(() {
                                        if (isCollapsed) {
                                          _collapsed.remove(key);
                                        } else {
                                          _collapsed.add(key);
                                        }
                                      }),
                                      onDeleteGroup: key == null
                                          ? null
                                          : () => _confirmDeleteGroup(
                                              context,
                                              ref,
                                              label,
                                              list
                                                  .where(
                                                    (server) =>
                                                        server.subscriptionId ==
                                                        key,
                                                  )
                                                  .toList(),
                                              key,
                                              s,
                                            ),
                                      deleteTooltip: s.deleteGroupTitle(label),
                                    ),
                                  ),
                                );
                                if (!isCollapsed) {
                                  for (final sv in group) {
                                    items.add(
                                      Material(
                                        color: Colors.transparent,
                                        child: ServerListTile(
                                          key: ValueKey(sv.id),
                                          server: sv,
                                          isSelected: sv.id == selected?.id,
                                          onTap: () => _selectServer(sv),
                                          onDelete: () => _confirmDelete(
                                            context,
                                            ref,
                                            sv,
                                            s,
                                          ),
                                          onTapDetail: () =>
                                              context.push('/servers/${sv.id}'),
                                        ),
                                      ),
                                    );
                                  }
                                }
                                if (key?.contains('sub.honeyvpn.ru') == true &&
                                    subs.length == 1 &&
                                    !group.any((sv) => sv.protocol == 'hy2')) {
                                  items.add(
                                    _HysteriaBanner(
                                      onTap: () =>
                                          context.push('/marketplace/honeyvpn'),
                                      ru: ru,
                                    ),
                                  );
                                }
                                items.add(const SizedBox(height: 8));
                              }
                              return SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                sliver: SliverList.builder(
                                  itemCount: items.length,
                                  itemBuilder: (_, i) => items[i],
                                ),
                              );
                            },
                          ),
                          const SliverToBoxAdapter(child: SizedBox(height: 24)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showServerChooser() async {
    final server = await showDialog<ServerProfileModel>(
      context: context,
      builder: (_) => const _ServerChooser(),
    );
    if (!mounted || server == null) return;
    await _selectServer(server);
  }

  Future<void> _selectServer(ServerProfileModel server) async {
    if (ref.read(connectionNotifierProvider).isBusy) return;
    final selected = await ref
        .read(serversNotifierProvider.notifier)
        .selectServerIfCurrent(server);
    if (!mounted) return;
    if (!selected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ref.read(stringsProvider).favoriteServerChanged),
        ),
      );
      return;
    }
    final current = ref.read(selectedServerProvider);
    if (current == null || !current.hasSameConnectionIdentity(server)) return;
    final conn = ref.read(connectionNotifierProvider);
    if (conn.isConnected && conn.activeServer?.id != current.id) {
      await ref.read(connectionNotifierProvider.notifier).connect(current);
    }
  }

  void _handleConnectTap(
    WidgetRef ref,
    NexConnectionState conn,
    ServerProfileModel? server,
  ) {
    if (conn.isBusy) return;
    if (conn.isConnected) {
      ref.read(connectionNotifierProvider.notifier).disconnect();
      return;
    }
    if (server == null) return;

    final disclosed = ref.read(vpnDisclosureProvider).value ?? false;
    if (!disclosed) {
      _showVpnDisclosure(ref, server);
    } else {
      ref.read(connectionNotifierProvider.notifier).connect(server);
    }
  }

  Future<void> _showVpnDisclosure(
    WidgetRef ref,
    ServerProfileModel server,
  ) async {
    final s = ref.read(stringsProvider);
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Row(
          children: [
            const Icon(Icons.vpn_lock_outlined, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Text(s.vpnDisclosureTitle)),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(s.vpnDisclosureBody, style: const TextStyle(height: 1.5)),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => launchUrl(
                Uri.parse('https://api.honeyvpn.ru/privacy#${s.locale}'),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(
                s.vpnDisclosurePrivacyLink,
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.vpnDisclosureDecline),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.vpnDisclosureAccept),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await ref.read(vpnDisclosureProvider.notifier).accept();
      if (mounted) {
        ref.read(connectionNotifierProvider.notifier).connect(server);
      }
    }
  }

  void _confirmDeleteGroup(
    BuildContext ctx,
    WidgetRef ref,
    String label,
    List<ServerProfileModel> group,
    String subscriptionId,
    S s,
  ) {
    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(s.deleteGroupTitle(label)),
        content: Text(
          s.deleteGroupContent(group.length, subscriptionId.isNotEmpty),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(s.cancelButton),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () async {
              Navigator.pop(c);
              final conn = ref.read(connectionNotifierProvider);
              final active = conn.activeServer;
              final affectsActive =
                  active != null &&
                  (group.any((sv) => sv.id == active.id) ||
                      (subscriptionId.isNotEmpty &&
                          active.subscriptionId == subscriptionId));
              if (!await _stopBeforeDelete(affectsActive, s)) return;
              if (subscriptionId.isNotEmpty) {
                final subs = ref.read(subscriptionsProvider).value?.subs ?? [];
                final sub = subs
                    .where((sub) => sub.url == subscriptionId)
                    .firstOrNull;
                if (sub != null) {
                  await ref.read(subscriptionsProvider.notifier).delete(sub.id);
                  return;
                }
              }
              for (final sv in group) {
                await ref
                    .read(serversNotifierProvider.notifier)
                    .delete(sv.id, expectedSubscriptionId: subscriptionId);
              }
            },
            child: Text(s.deleteButton),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(
    BuildContext ctx,
    WidgetRef ref,
    ServerProfileModel sv,
    S s,
  ) {
    showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(s.deleteServerTitle),
        content: Text(
          s.deleteServerContent(sv.name.isNotEmpty ? sv.name : sv.host),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(s.cancelButton),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () async {
              Navigator.pop(c);
              final conn = ref.read(connectionNotifierProvider);
              final active = conn.activeServer;
              final deletingFreeSlot =
                  normalizeSubscriptionUrl(sv.subscriptionId) ==
                  builtInSubscriptionUrl;
              final affectsActive =
                  active != null &&
                  (active.id == sv.id ||
                      (deletingFreeSlot &&
                          normalizeSubscriptionUrl(active.subscriptionId) ==
                              builtInSubscriptionUrl));
              if (!await _stopBeforeDelete(affectsActive, s)) return;
              await ref
                  .read(serversNotifierProvider.notifier)
                  .delete(sv.id, expectedSubscriptionId: sv.subscriptionId);
            },
            child: Text(s.deleteButton),
          ),
        ],
      ),
    );
  }

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

  static String _hostFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host.isNotEmpty ? uri.host : url;
    } catch (_) {
      return url;
    }
  }
}

// Connection controls stay outside the scrolling server content so their
// target never moves when connection feedback or server lists change.
class _ConnectionControls extends StatelessWidget {
  final NexConnectionState conn;
  final ServerProfileModel? selected;
  final S s;
  final bool compact;
  final VoidCallback onConnectTap;
  final VoidCallback onServerTap;

  const _ConnectionControls({
    required this.conn,
    required this.selected,
    required this.s,
    this.compact = false,
    required this.onConnectTap,
    required this.onServerTap,
  });

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.sizeOf(context);
    final desktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    // A full-height desktop panel gives the primary action room to breathe.
    // Short or narrow windows retain the compact target and scrollable content.
    final generous = desktop && window.width >= 400 && window.height >= 640;
    final nativeSession =
        conn.usesNativeSessionIdentity &&
        conn.status != ConnectionStatus.disconnected;
    final current = nativeSession
        ? conn.activeServer
        : conn.isConnected || conn.isBusy
        ? conn.activeServer ?? selected
        : selected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (generous) const SizedBox(height: 24),
        ConnectButton(
          status: conn.status,
          // Enlarged text adds 24px inside ConnectButton: the tight Windows
          // target remains 144px while leaving a usable server viewport.
          diameter: generous
              ? 224
              : compact
              ? 120
              : 160,
          enabled:
              selected != null || conn.activeServer != null || conn.isConnected,
          onTap: onConnectTap,
        ),
        SizedBox(
          height: generous
              ? 16
              : compact
              ? 4
              : 10,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: ServerSelectorChip(
            server: current,
            labelOverride: nativeSession && current == null
                ? s.activeServerUnknown
                : null,
            onTap: onServerTap,
          ),
        ),
      ],
    );
  }
}

// Windows mode stays below the fixed primary action and above live metrics.
class _ConnectionModeControl extends StatelessWidget {
  final NexConnectionState conn;
  final S s;
  final ConnectionMode connectionMode;
  final ValueChanged<ConnectionMode> onModeChanged;

  const _ConnectionModeControl({
    required this.conn,
    required this.s,
    required this.connectionMode,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) => SegmentedButton<ConnectionMode>(
    showSelectedIcon: false,
    segments: [
      ButtonSegment(
        value: ConnectionMode.tunnel,
        icon: const Icon(Icons.vpn_lock_outlined, size: 18),
        label: Text(
          s.connectionModeShortLabel('tunnel'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        tooltip: s.connectionModeShortLabel('tunnel'),
      ),
      ButtonSegment(
        value: ConnectionMode.proxy,
        icon: const Icon(Icons.device_hub_outlined, size: 18),
        label: Text(
          s.connectionModeShortLabel('proxy'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        tooltip: s.connectionModeShortLabel('proxy'),
      ),
    ],
    selected: {connectionMode},
    onSelectionChanged: conn.isBusy || conn.isConnected
        ? null
        : (selection) => onModeChanged(selection.first),
  );
}

class _ServerChooser extends ConsumerWidget {
  const _ServerChooser();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final cs = Theme.of(context).colorScheme;
    final servers = ref.watch(serversNotifierProvider);
    final selected = ref.watch(selectedServerProvider);
    final conn = ref.watch(connectionNotifierProvider);
    final subs = ref.watch(subscriptionsProvider).value?.subs ?? [];
    final subNames = <String, String>{
      for (final sub in subs)
        sub.url: sub.name.isNotEmpty
            ? sub.name
            : _HomeScreenState._hostFromUrl(sub.url),
    };
    return Dialog(
      key: const ValueKey('all-servers-chooser'),
      insetPadding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(maxWidth: 440),
      child: SizedBox(
        height: (MediaQuery.sizeOf(context).height * 0.75).clamp(240.0, 520.0),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 6, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.chooseServer,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (servers.value?.isNotEmpty == true)
                    const LatencyTestAction(),
                  IconButton(
                    tooltip: s.closeButton,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            if (conn.isBusy)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  s.serverSelectionLocked,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            Expanded(
              child: servers.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(s.serversLoadFailed),
                  ),
                ),
                data: (all) {
                  if (all.isEmpty) {
                    return Center(child: Text(s.noServersYet));
                  }
                  final groups = serverSelectionGroups(all, subs);
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    children: [
                      for (final group in groups) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                          child: Text(
                            group.subscriptionId == null
                                ? s.favoritesTitle
                                : group.subscriptionId!.isEmpty
                                ? s.manualGroup
                                : subNames[group.subscriptionId] ??
                                      _HomeScreenState._hostFromUrl(
                                        group.subscriptionId!,
                                      ),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                        for (final server in group.servers)
                          ListTile(
                            key: ValueKey('choose-server-${server.id}'),
                            enabled: !conn.isBusy,
                            selected: selected?.id == server.id,
                            selectedTileColor: cs.primary.withValues(
                              alpha: 0.065,
                            ),
                            visualDensity: VisualDensity.compact,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 2,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(7),
                            ),
                            leading: CountryFlagIcon(
                              presentation: CountryPresentation.fromName(
                                server.name,
                                fallbackName: server.host,
                              ),
                            ),
                            minLeadingWidth: 20,
                            horizontalTitleGap: 10,
                            title: Text(
                              CountryPresentation.fromName(
                                server.name,
                                fallbackName: server.host,
                              ).displayName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              group.subscriptionId == null
                                  ? '${server.subscriptionId.isEmpty ? s.manualGroup : subNames[server.subscriptionId] ?? _HomeScreenState._hostFromUrl(server.subscriptionId)} · ${ServerConnectionLabel.fromProfile(server)}'
                                  : ServerConnectionLabel.fromProfile(server),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (ref
                                    .watch(latencyTestProgressProvider)
                                    .activeIds
                                    .contains(server.id))
                                  const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                    ),
                                  )
                                else if (server.latencyMs != null)
                                  LatencyBadge(ms: server.latencyMs!),
                              ],
                            ),
                            onTap: () => Navigator.pop(context, server),
                          ),
                      ],
                    ],
                  );
                },
              ),
            ),
            if (servers.value?.isEmpty == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextButton.icon(
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(s.importServerButton),
                  onPressed: () {
                    Navigator.pop(context);
                    context.push('/converter');
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Group header ───────────────────────────────────────────────────────────────

class _GroupHeader extends ConsumerWidget {
  final String label;
  final bool hasRefreshFailure;
  final String? geoWarning;
  final int count;
  final bool isManual;
  final bool isFavorites;
  final bool isCollapsed;
  final VoidCallback onToggle;
  final VoidCallback? onDeleteGroup;
  final String deleteTooltip;

  const _GroupHeader({
    super.key,
    required this.label,
    required this.hasRefreshFailure,
    this.geoWarning,
    required this.count,
    required this.isManual,
    this.isFavorites = false,
    required this.isCollapsed,
    required this.onToggle,
    required this.onDeleteGroup,
    required this.deleteTooltip,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final s = ref.watch(stringsProvider);
    final ru = s.locale == 'ru';
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onToggle,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                10,
                MediaQuery.sizeOf(context).width >= 700 ? 7 : 10,
                4,
                MediaQuery.sizeOf(context).width >= 700 ? 7 : 10,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isFavorites) ...[
                          Icon(Icons.star_rounded, size: 14, color: cs.primary),
                          const SizedBox(width: 5),
                        ],
                        Flexible(
                          child: Text(
                            label,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (hasRefreshFailure || geoWarning != null) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: hasRefreshFailure
                                ? s.subscriptionRefreshFailureTooltip
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
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$count',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    isCollapsed
                        ? Icons.expand_more_rounded
                        : Icons.expand_less_rounded,
                    size: 16,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (onDeleteGroup != null)
          PopupMenuButton<bool>(
            tooltip: isManual
                ? (ru ? 'Действия с группой' : 'Group actions')
                : (ru ? 'Действия с подпиской' : 'Subscription actions'),
            icon: Icon(
              Icons.more_horiz_rounded,
              size: 16,
              color: cs.onSurfaceVariant,
            ),
            onSelected: (_) => onDeleteGroup!(),
            itemBuilder: (_) => [
              PopupMenuItem(
                height: MediaQuery.sizeOf(context).width >= 700 ? 34 : 44,
                value: true,
                child: Text(s.deleteButton, style: TextStyle(color: cs.error)),
              ),
            ],
          ),
      ],
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            s.noServersYet,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
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

class _ErrorBanner extends ConsumerWidget {
  final String message;
  const _ErrorBanner({required this.message});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final ru = ref.watch(stringsProvider).locale == 'ru';
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cs.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: cs.onErrorContainer,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: cs.onErrorContainer,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
            IconButton(
              onPressed: () => showDiagnosticSendSheet(context),
              tooltip: ru ? 'Отправить диагностику' : 'Send diagnostics',
              icon: const Icon(Icons.upload_outlined, size: 20),
              color: cs.onErrorContainer,
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateBanner extends ConsumerStatefulWidget {
  final UpdateInfo info;
  final VoidCallback onDismiss;
  const _UpdateBanner({required this.info, required this.onDismiss});

  @override
  ConsumerState<_UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<_UpdateBanner> {
  double? _progress;

  Future<void> _install() async {
    if (isPlayFlavor) {
      await launchUrl(Uri.parse('market://details?id=ru.honeyvpn.proxy'));
      return;
    }
    final url = widget.info.downloadUrl;
    if (url.isEmpty) return;
    if (kIsWeb || !Platform.isAndroid) {
      await launchUrl(Uri.parse(url));
      return;
    }

    // Android 8+: need special permission to install APKs
    final canInstall = await Permission.requestInstallPackages.isGranted;
    if (!canInstall) {
      // Opens Settings → "Install unknown apps" for this app
      await Permission.requestInstallPackages.request();
      return;
    }

    setState(() => _progress = 0);
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/update.apk';
      await Dio().download(
        url,
        path,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _progress = received / total);
          }
        },
      );
      final result = await OpenFile.open(path);
      if (result.type != ResultType.done) {
        // OpenFile failed — fall back to browser download
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ru = ref.watch(stringsProvider).locale == 'ru';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.system_update_outlined, color: cs.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ru
                          ? 'Доступна версия ${widget.info.remoteVersion}'
                          : 'Version ${widget.info.remoteVersion} available',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ru
                          ? 'Установлена ${widget.info.currentVersion}'
                          : 'Installed ${widget.info.currentVersion}',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: widget.onDismiss,
                tooltip: ru ? 'Закрыть' : 'Dismiss',
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _progress != null ? null : _install,
              icon: const Icon(Icons.download_rounded, size: 17),
              label: Text(
                _progress != null
                    ? '${(_progress! * 100).toInt()}%'
                    : (ru ? 'Обновить приложение' : 'Update app'),
              ),
            ),
          ),
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.only(right: 10, bottom: 4),
              child: LinearProgressIndicator(value: _progress, minHeight: 3),
            ),
        ],
      ),
    );
  }
}

// A quiet entry to the existing plans screen, without a promotional card.
class _HysteriaBanner extends StatelessWidget {
  final VoidCallback onTap;
  final bool ru;
  const _HysteriaBanner({required this.onTap, required this.ru});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ru ? 'Тарифы HoneyVPN' : 'HoneyVPN plans',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.arrow_forward_rounded, size: 14),
          ],
        ),
      ),
    );
  }
}
