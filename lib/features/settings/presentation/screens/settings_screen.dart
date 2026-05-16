import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../../app/app_theme.dart';
import '../../../../app/l10n/strings.dart';
import '../notifiers/settings_notifier.dart';
import '../../data/models/app_settings.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final notifier = ref.read(settingsProvider.notifier);
    final s = ref.watch(stringsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(s.settingsTitle)),
      body: ListView(
        children: [
          // ── Appearance ───────────────────────────────────────────────────
          _SectionHeader(s.appearanceSection),
          _SettingsTile(
            icon: Icons.palette_outlined,
            title: s.themeTitle,
            subtitle: _themeLabel(settings.themeMode, s),
            trailing: _ThemeToggle(current: settings.themeMode, onChanged: notifier.setTheme, s: s),
          ),
          _SettingsTile(
            icon: Icons.language_outlined,
            title: s.languageTitle,
            subtitle: settings.locale == 'ru' ? 'Русский' : 'English',
            trailing: _LangToggle(current: settings.locale, onChanged: notifier.setLocale),
          ),

          // ── Connection ───────────────────────────────────────────────────
          const Divider(height: 8),
          _SectionHeader(s.connectionSection),

          if (kIsWeb || !Platform.isAndroid)
            _SettingsTile(
              icon: settings.connectionMode.icon,
              title: s.modeTitle,
              subtitle: settings.connectionMode.description,
              trailing: _ModeToggle(current: settings.connectionMode, onChanged: notifier.setConnectionMode, s: s),
            ),

          _SettingsTile(
            icon: Icons.route_outlined,
            title: s.routingTitle,
            subtitle: settings.routingMode.description,
            onTap: () => context.push('/settings/routing'),
            trailing: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(settings.routingMode.label,
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary)),
                const Icon(Icons.chevron_right, size: 18),
              ]),
            ),
          ),

          _SettingsTile(
            icon: Icons.dns_outlined,
            title: s.dnsTitle,
            subtitle: settings.dnsPreset == DnsPreset.custom
                ? settings.customDnsUrl.isNotEmpty ? settings.customDnsUrl : 'Custom (not set)'
                : '${settings.dnsPreset.label} · DoH',
            onTap: () => context.push('/settings/dns'),
            trailing: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(settings.dnsPreset.ip,
                    style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const Icon(Icons.chevron_right, size: 18),
              ]),
            ),
          ),

          _SettingsTile(
            icon: Icons.call_split_outlined,
            title: s.splitTunnelTitle,
            subtitle: s.splitTunnelSubtitle,
            onTap: () => context.push('/settings/split-tunnel'),
          ),

          _SettingsTile(
            icon: Icons.lan_outlined,
            title: s.preferredIpTitle,
            subtitle: s.preferredIpSubtitle(settings.preferredIpType.label),
            trailing: _IpTypeToggle(
              current: settings.preferredIpType,
              onChanged: notifier.setIpType,
            ),
          ),

          _SwitchTile(
            icon: Icons.developer_board_outlined,
            title: s.fragmentationTitle,
            subtitle: s.fragmentationSubtitle,
            value: settings.fragmentationEnabled,
            onChanged: notifier.setFragmentation,
          ),

          _SwitchTile(
            icon: Icons.multiple_stop_outlined,
            title: s.multiplexerTitle,
            subtitle: s.multiplexerSubtitle,
            value: settings.multiplexerEnabled,
            onChanged: notifier.setMultiplexer,
          ),

          _SwitchTile(
            icon: Icons.wifi_tethering_outlined,
            title: s.allowLanTitle,
            subtitle: s.allowLanSubtitle,
            value: settings.allowLanConnections,
            onChanged: notifier.setAllowLan,
          ),

          _SwitchTile(
            icon: Icons.block_outlined,
            title: s.blockAdsTitle,
            subtitle: s.blockAdsSubtitle,
            value: settings.blockAds,
            onChanged: notifier.setBlockAds,
          ),

          _SwitchTile(
            icon: Icons.dns_outlined,
            title: s.fakeipTitle,
            subtitle: s.fakeipSubtitle,
            value: settings.enableFakeip,
            onChanged: notifier.setFakeip,
          ),

          if (!kIsWeb && Platform.isAndroid)
            _SettingsTile(
              icon: Icons.layers_outlined,
              title: s.tunStackTitle,
              subtitle: s.tunStackSubtitle(settings.tunStack.label),
              trailing: _TunStackToggle(current: settings.tunStack, onChanged: notifier.setTunStack),
            ),

          // ── Advanced ─────────────────────────────────────────────────────
          const Divider(height: 8),
          _SectionHeader(s.advancedSection),
          _SettingsTile(
            icon: Icons.terminal_outlined,
            title: s.logsTitle,
            subtitle: s.logsSubtitle,
            onTap: () => context.push('/settings/log'),
          ),
          _SettingsTile(
            icon: Icons.filter_list_outlined,
            title: s.logLevelTitle,
            subtitle: settings.logLevel.label,
            trailing: _LogLevelMenu(current: settings.logLevel, onChanged: notifier.setLogLevel),
          ),
          _SettingsTile(
            icon: Icons.settings_ethernet_outlined,
            title: s.portsTitle,
            subtitle: 'SOCKS ${settings.socksPort}  ·  HTTP ${settings.httpPort}',
            onTap: () => _showPortsDialog(context, ref, settings, notifier, s),
          ),
          _SettingsTile(
            icon: Icons.link_outlined,
            title: s.urlSchemesTitle,
            subtitle: s.urlSchemesSubtitle,
            onTap: () => context.push('/settings/url-schemes'),
          ),

          // ── About ─────────────────────────────────────────────────────────
          const Divider(height: 8),
          _SectionHeader(s.aboutSection),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (ctx, snap) => _SettingsTile(
              icon: Icons.info_outline,
              title: 'HoneyProxyUtility',
              subtitle: snap.data != null
                  ? 'v${snap.data!.version}+${snap.data!.buildNumber}'
                  : 'v1.0.0',
            ),
          ),
        ],
      ),
    );
  }

  String _themeLabel(ThemeMode mode, S s) => switch (mode) {
    ThemeMode.system => s.themeSystem,
    ThemeMode.light  => s.themeLight,
    ThemeMode.dark   => s.themeDark,
  };

  void _showPortsDialog(BuildContext context, WidgetRef ref, AppSettings settings, SettingsNotifier notifier, S s) {
    final socksCtrl = TextEditingController(text: settings.socksPort.toString());
    final httpCtrl  = TextEditingController(text: settings.httpPort.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.portsTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: socksCtrl,
              decoration: const InputDecoration(labelText: 'SOCKS5 Port'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: httpCtrl,
              decoration: const InputDecoration(labelText: 'HTTP Port'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancelButton)),
          FilledButton(
            onPressed: () {
              final socks = int.tryParse(socksCtrl.text) ?? settings.socksPort;
              final http  = int.tryParse(httpCtrl.text)  ?? settings.httpPort;
              if (socks > 0 && socks < 65536) notifier.setSocksPort(socks);
              if (http  > 0 && http  < 65536) notifier.setHttpPort(http);
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

// ── Theme toggle ──────────────────────────────────────────────────────────────

class _ThemeToggle extends StatelessWidget {
  final ThemeMode current;
  final ValueChanged<ThemeMode> onChanged;
  final S s;
  const _ThemeToggle({required this.current, required this.onChanged, required this.s});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SegmentedButton<ThemeMode>(
      segments: const [
        ButtonSegment(value: ThemeMode.light,  icon: Icon(Icons.light_mode_outlined,  size: 16)),
        ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto,       size: 16)),
        ButtonSegment(value: ThemeMode.dark,   icon: Icon(Icons.dark_mode_outlined,    size: 16)),
      ],
      selected: {current},
      onSelectionChanged: (sel) => onChanged(sel.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: WidgetStateProperty.all(BorderSide(color: cs.outline.withOpacity(0.25))),
      ),
      showSelectedIcon: false,
    );
  }
}

// ── Language toggle ───────────────────────────────────────────────────────────

class _LangToggle extends StatelessWidget {
  final String current;
  final ValueChanged<String> onChanged;
  const _LangToggle({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: 'en', label: Text('EN', style: TextStyle(fontSize: 12))),
        ButtonSegment(value: 'ru', label: Text('RU', style: TextStyle(fontSize: 12))),
      ],
      selected: {current},
      onSelectionChanged: (sel) => onChanged(sel.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: WidgetStateProperty.all(BorderSide(color: cs.outline.withOpacity(0.25))),
      ),
      showSelectedIcon: false,
    );
  }
}

// ── Mode toggle ───────────────────────────────────────────────────────────────

class _ModeToggle extends StatelessWidget {
  final ConnectionMode current;
  final ValueChanged<ConnectionMode> onChanged;
  final S s;
  const _ModeToggle({required this.current, required this.onChanged, required this.s});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SegmentedButton<ConnectionMode>(
      segments: const [
        ButtonSegment(value: ConnectionMode.tunnel, label: Text('Tunnel', style: TextStyle(fontSize: 12))),
        ButtonSegment(value: ConnectionMode.proxy,  label: Text('Proxy',  style: TextStyle(fontSize: 12))),
      ],
      selected: {current},
      onSelectionChanged: (sel) => onChanged(sel.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: WidgetStateProperty.all(BorderSide(color: cs.outline.withOpacity(0.25))),
      ),
      showSelectedIcon: false,
    );
  }
}

// ── IP Type toggle ────────────────────────────────────────────────────────────

class _IpTypeToggle extends StatelessWidget {
  final IpType current;
  final ValueChanged<IpType> onChanged;
  const _IpTypeToggle({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SegmentedButton<IpType>(
      segments: const [
        ButtonSegment(value: IpType.ipv4, label: Text('v4',   style: TextStyle(fontSize: 11))),
        ButtonSegment(value: IpType.both, label: Text('Both', style: TextStyle(fontSize: 11))),
        ButtonSegment(value: IpType.ipv6, label: Text('v6',   style: TextStyle(fontSize: 11))),
      ],
      selected: {current},
      onSelectionChanged: (sel) => onChanged(sel.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: WidgetStateProperty.all(BorderSide(color: cs.outline.withOpacity(0.25))),
      ),
      showSelectedIcon: false,
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.9,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: NexPalette.accent, size: 20),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: subtitle.isNotEmpty ? Text(subtitle, style: const TextStyle(fontSize: 11)) : null,
    trailing: trailing ?? (onTap != null ? const Icon(Icons.chevron_right, size: 18) : null),
    onTap: onTap,
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
  );
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: NexPalette.accent, size: 20),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
    trailing: Switch(value: value, onChanged: onChanged),
    onTap: () => onChanged(!value),
    dense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
  );
}

// ── TUN stack toggle ──────────────────────────────────────────────────────────

class _TunStackToggle extends StatelessWidget {
  final TunStack current;
  final ValueChanged<TunStack> onChanged;
  const _TunStackToggle({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SegmentedButton<TunStack>(
      segments: const [
        ButtonSegment(value: TunStack.system, label: Text('Sys',    style: TextStyle(fontSize: 11))),
        ButtonSegment(value: TunStack.mixed,  label: Text('Mixed',  style: TextStyle(fontSize: 11))),
        ButtonSegment(value: TunStack.gvisor, label: Text('gVisor', style: TextStyle(fontSize: 11))),
      ],
      selected: {current},
      onSelectionChanged: (sel) => onChanged(sel.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: WidgetStateProperty.all(BorderSide(color: cs.outline.withOpacity(0.25))),
      ),
      showSelectedIcon: false,
    );
  }
}

// ── Log level menu ────────────────────────────────────────────────────────────

class _LogLevelMenu extends StatelessWidget {
  final LogLevel current;
  final ValueChanged<LogLevel> onChanged;
  const _LogLevelMenu({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<LogLevel>(
      tooltip: 'Log level',
      initialValue: current,
      onSelected: onChanged,
      itemBuilder: (_) => LogLevel.values.map((l) => PopupMenuItem(
        value: l,
        child: Row(
          children: [
            Icon(Icons.circle, size: 8,
              color: l == LogLevel.error ? NexColors.error
                   : l == LogLevel.warn  ? NexColors.connecting
                   : cs.onSurface.withOpacity(0.4)),
            const SizedBox(width: 8),
            Text(l.label),
          ],
        ),
      )).toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(current.label, style: TextStyle(fontSize: 12, color: cs.onSurface)),
            Icon(Icons.arrow_drop_down, size: 18, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
