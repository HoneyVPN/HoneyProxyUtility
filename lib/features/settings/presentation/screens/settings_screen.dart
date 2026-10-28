import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../../app/app_theme.dart';
import '../../../../app/l10n/strings.dart';
import '../notifiers/settings_notifier.dart';
import '../../data/models/app_settings.dart';
import '../widgets/yunicode_credit.dart';
import '../widgets/settings_save_feedback.dart';
import '../../../diagnostics/presentation/diagnostic_auto_send_gate.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final notifier = ref.read(settingsProvider.notifier);
    final s = ref.watch(stringsProvider);
    Future<void> save(Future<void> Function() update) =>
        saveSettingsWithFeedback(context, update, s.settingsSaveFailed);
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final isApple =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final supportsTunStack =
        isWindows && settings.connectionMode == ConnectionMode.tunnel;
    final supportsProxyListeners =
        !isApple &&
        (!isWindows || settings.connectionMode == ConnectionMode.proxy);

    return Scaffold(
      appBar: AppBar(title: Text(s.settingsTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              ..._groupSettings(context, [
                // ── Appearance ───────────────────────────────────────────────────
                _SectionHeader(s.appearanceSection),
                _SettingsTile(
                  icon: Icons.palette_outlined,
                  title: s.themeTitle,
                  trailing: _ThemeToggle(
                    current: settings.themeMode,
                    onChanged: (value) => save(() => notifier.setTheme(value)),
                    s: s,
                  ),
                ),
                _SettingsTile(
                  icon: Icons.language_outlined,
                  title: s.languageTitle,
                  trailing: _LangToggle(
                    current: settings.locale,
                    onChanged: (value) => save(() => notifier.setLocale(value)),
                  ),
                ),

                // ── Connection ───────────────────────────────────────────────────
                const Divider(height: 8),
                _SectionHeader(s.connectionSection),

                if (isWindows)
                  _SettingsTile(
                    icon: settings.connectionMode.icon,
                    title: s.modeTitle,
                    subtitle: settings.connectionMode == ConnectionMode.proxy
                        ? s.connectionModeDescription(
                            settings.connectionMode.name,
                            settings.socksPort,
                            settings.httpPort,
                          )
                        : '',
                    trailing: _ModeToggle(
                      current: settings.connectionMode,
                      onChanged: (value) =>
                          save(() => notifier.setConnectionMode(value)),
                      s: s,
                    ),
                  ),

                if (isApple && settings.connectionMode == ConnectionMode.proxy)
                  _SettingsTile(
                    icon: Icons.vpn_lock_outlined,
                    title: s.modeTitle,
                    subtitle: s.appleProxyModeSaved,
                    trailing: settings.connectionMode == ConnectionMode.proxy
                        ? TextButton(
                            onPressed: () => save(
                              () => notifier.setConnectionMode(
                                ConnectionMode.tunnel,
                              ),
                            ),
                            child: Text(s.useVpnTunnel),
                          )
                        : null,
                  ),

                _SettingsTile(
                  icon: Icons.route_outlined,
                  title: s.routingTitle,
                  onTap: () => context.push('/settings/routing'),
                  trailing: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            s.routingModeLabel(settings.routingMode.name),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        const Icon(Icons.chevron_right, size: 18),
                      ],
                    ),
                  ),
                ),

                _SettingsTile(
                  icon: Icons.dns_outlined,
                  title: s.dnsTitle,
                  onTap: () => context.push('/settings/dns'),
                  trailing: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            s.dnsPresetLabel(settings.dnsPreset.name),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const Icon(Icons.chevron_right, size: 18),
                      ],
                    ),
                  ),
                ),

                // ── Advanced ─────────────────────────────────────────────────────
                _SettingsNote(s.connectionSettingsApplyNext),
                const Divider(height: 8),
                _SectionHeader(s.advancedSection),
                _SettingsTile(
                  icon: Icons.lan_outlined,
                  title: s.preferredIpTitle,
                  subtitle: s.preferredIpSubtitle(
                    settings.preferredIpType.name,
                  ),
                  trailing: _IpTypeToggle(
                    current: settings.preferredIpType,
                    onChanged: (value) => save(() => notifier.setIpType(value)),
                    s: s,
                  ),
                ),

                _SwitchTile(
                  icon: Icons.developer_board_outlined,
                  title: s.fragmentationTitle,
                  subtitle: s.fragmentationSubtitle,
                  value: settings.fragmentationEnabled,
                  onChanged: (value) =>
                      save(() => notifier.setFragmentation(value)),
                ),

                _SwitchTile(
                  icon: Icons.multiple_stop_outlined,
                  title: s.multiplexerTitle,
                  subtitle: s.multiplexerSubtitle,
                  value: settings.multiplexerEnabled,
                  onChanged: (value) =>
                      save(() => notifier.setMultiplexer(value)),
                ),

                if (supportsProxyListeners)
                  _SwitchTile(
                    icon: Icons.wifi_tethering_outlined,
                    title: s.allowLanTitle,
                    subtitle: s.allowLanSubtitle,
                    value: settings.allowLanConnections,
                    onChanged: (value) =>
                        save(() => notifier.setAllowLan(value)),
                  ),

                if (supportsTunStack)
                  _SettingsTile(
                    icon: Icons.layers_outlined,
                    title: s.tunStackTitle,
                    trailing: supportsTunStack
                        ? _TunStackToggle(
                            current: settings.tunStack,
                            onChanged: (value) =>
                                save(() => notifier.setTunStack(value)),
                          )
                        : null,
                  ),

                _SettingsTile(
                  icon: Icons.terminal_outlined,
                  title: s.logsTitle,
                  onTap: () => context.push('/settings/log'),
                ),
                const AutomaticDiagnosticsTile(),
                if (!isWindows && !isApple)
                  _SettingsTile(
                    icon: Icons.filter_list_outlined,
                    title: s.logLevelTitle,
                    subtitle: s.coreLogLevelSubtitle,
                    trailing: _LogLevelMenu(
                      current: settings.logLevel,
                      onChanged: (value) =>
                          save(() => notifier.setLogLevel(value)),
                      s: s,
                    ),
                  ),
                if (supportsProxyListeners)
                  _SettingsTile(
                    icon: Icons.settings_ethernet_outlined,
                    title: s.portsTitle,
                    subtitle:
                        'SOCKS ${settings.socksPort}  ·  HTTP ${settings.httpPort}',
                    onTap: () =>
                        _showPortsDialog(context, settings, notifier, s),
                  ),
                _SettingsTile(
                  icon: Icons.link_outlined,
                  title: s.urlSchemesTitle,
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
                        : snap.hasError
                        ? s.versionUnavailable
                        : s.loading,
                  ),
                ),
              ]),
              const SizedBox(height: 20),
              YuNiCodeCredit(caption: s.developerCreditCaption),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPortsDialog(
    BuildContext context,
    AppSettings settings,
    SettingsNotifier notifier,
    S s,
  ) => showDialog<void>(
    context: context,
    builder: (_) => _ProxyPortsDialog(
      socksPort: settings.socksPort,
      httpPort: settings.httpPort,
      onSave: notifier.setPorts,
      s: s,
    ),
  );
}

class _ProxyPortsDialog extends StatefulWidget {
  const _ProxyPortsDialog({
    required this.socksPort,
    required this.httpPort,
    required this.onSave,
    required this.s,
  });

  final int socksPort;
  final int httpPort;
  final Future<void> Function(int, int) onSave;
  final S s;

  @override
  State<_ProxyPortsDialog> createState() => _ProxyPortsDialogState();
}

class _ProxyPortsDialogState extends State<_ProxyPortsDialog> {
  late final TextEditingController _socksController;
  late final TextEditingController _httpController;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _socksController = TextEditingController(text: '${widget.socksPort}');
    _httpController = TextEditingController(text: '${widget.httpPort}');
  }

  @override
  void dispose() {
    _socksController.dispose();
    _httpController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final socks = int.tryParse(_socksController.text);
    final http = int.tryParse(_httpController.text);
    final ru = widget.s.locale == 'ru';
    try {
      if (socks == null || http == null) {
        throw SettingsValidationException(SettingsValidationIssue.ports);
      }
      AppSettings.validatePorts(socks, http);
    } on SettingsValidationException {
      setState(() => _error = widget.s.invalidPorts);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(socks, http);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = ru
            ? 'Не удалось сохранить. Попробуйте ещё раз.'
            : 'Could not save. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final ru = s.locale == 'ru';
    return AlertDialog(
      title: Text(s.portsTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _socksController,
            enabled: !_saving,
            decoration: const InputDecoration(labelText: 'SOCKS5'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _httpController,
            enabled: !_saving,
            decoration: const InputDecoration(labelText: 'HTTP'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(s.cancelButton),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(
            _saving
                ? (ru ? 'Сохранение…' : 'Saving…')
                : (ru ? 'Сохранить' : 'Save'),
          ),
        ),
      ],
    );
  }
}

// ── Theme toggle ──────────────────────────────────────────────────────────────

class _ThemeToggle extends StatelessWidget {
  final ThemeMode current;
  final ValueChanged<ThemeMode> onChanged;
  final S s;
  const _ThemeToggle({
    required this.current,
    required this.onChanged,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ThemeMode>(
      segments: [
        ButtonSegment(
          tooltip: s.themeLight,
          value: ThemeMode.light,
          icon: Icon(Icons.light_mode_outlined, size: 16),
        ),
        ButtonSegment(
          tooltip: s.themeSystem,
          value: ThemeMode.system,
          icon: Icon(Icons.desktop_mac_outlined, size: 16),
        ),
        ButtonSegment(
          tooltip: s.themeDark,
          value: ThemeMode.dark,
          icon: Icon(Icons.dark_mode_outlined, size: 16),
        ),
      ],
      selected: {current},
      onSelectionChanged: (sel) => onChanged(sel.first),
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
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(
          value: 'en',
          label: Text('EN', style: TextStyle(fontSize: 12)),
        ),
        ButtonSegment(
          value: 'ru',
          label: Text('RU', style: TextStyle(fontSize: 12)),
        ),
      ],
      selected: {current},
      onSelectionChanged: (sel) => onChanged(sel.first),
      showSelectedIcon: false,
    );
  }
}

// ── Mode toggle ───────────────────────────────────────────────────────────────

class _ModeToggle extends StatelessWidget {
  final ConnectionMode current;
  final ValueChanged<ConnectionMode> onChanged;
  final S s;
  const _ModeToggle({
    required this.current,
    required this.onChanged,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ConnectionMode>(
      direction: _settingsSegmentDirection(context),
      segments: [
        ButtonSegment(
          value: ConnectionMode.tunnel,
          label: Text(
            s.connectionModeShortLabel('tunnel'),
            style: const TextStyle(fontSize: 12),
          ),
        ),
        ButtonSegment(
          value: ConnectionMode.proxy,
          label: Text(
            s.connectionModeShortLabel('proxy'),
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
      selected: {current},
      onSelectionChanged: (sel) => onChanged(sel.first),
      showSelectedIcon: false,
    );
  }
}

// ── IP Type toggle ────────────────────────────────────────────────────────────

class _IpTypeToggle extends StatelessWidget {
  final IpType current;
  final ValueChanged<IpType> onChanged;
  final S s;
  const _IpTypeToggle({
    required this.current,
    required this.onChanged,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<IpType>(
      direction: _settingsSegmentDirection(context),
      segments: [
        ButtonSegment(
          value: IpType.ipv4,
          label: Text('IPv4', style: TextStyle(fontSize: 11)),
        ),
        ButtonSegment(
          value: IpType.both,
          label: Text(s.ipTypeBothLabel, style: const TextStyle(fontSize: 11)),
        ),
        ButtonSegment(
          value: IpType.ipv6,
          label: Text('IPv6', style: TextStyle(fontSize: 11)),
        ),
      ],
      selected: {current},
      onSelectionChanged: (sel) => onChanged(sel.first),
      showSelectedIcon: false,
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Axis _settingsSegmentDirection(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 500 &&
        MediaQuery.textScalerOf(context).scale(14) > 20
    ? Axis.vertical
    : Axis.horizontal;

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _SettingsNote extends StatelessWidget {
  const _SettingsNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    this.subtitle = '',
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width >= 700;
    final control =
        trailing ??
        (onTap != null
            ? Icon(
                Icons.chevron_right_rounded,
                size: 19,
                color: cs.onSurfaceVariant,
              )
            : null);
    return LayoutBuilder(
      builder: (context, constraints) {
        final stack =
            trailing != null &&
            trailing is! Switch &&
            trailing is! _LogLevelMenu &&
            (constraints.maxWidth < 340 ||
                MediaQuery.textScalerOf(context).scale(14) > 20);
        final description = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w400,
                fontSize: compact ? 13 : 14,
              ),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        );
        return InkWell(
          key: ValueKey('settings-row-$title'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: compact ? 42 : 52),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: compact ? 8 : 10,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(icon, color: cs.onSurfaceVariant, size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: description),
                      if (!stack && control != null) ...[
                        const SizedBox(width: 12),
                        control,
                      ],
                    ],
                  ),
                  if (stack)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, left: 28),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: control,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    this.subtitle = '',
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: _SettingsTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch.adaptive(
        key: ValueKey('setting-switch-$title'),
        value: value,
        onChanged: onChanged,
      ),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    ),
  );
}

// ── TUN stack toggle ──────────────────────────────────────────────────────────

class _TunStackToggle extends ConsumerWidget {
  final TunStack current;
  final ValueChanged<TunStack> onChanged;
  const _TunStackToggle({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    return SegmentedButton<TunStack>(
      direction: _settingsSegmentDirection(context),
      segments: [
        ButtonSegment(
          value: TunStack.system,
          label: Text(
            strings.systemTunStack,
            style: const TextStyle(fontSize: 11),
          ),
        ),
        ButtonSegment(
          value: TunStack.mixed,
          label: Text(
            strings.mixedTunStack,
            style: const TextStyle(fontSize: 11),
          ),
        ),
        const ButtonSegment(
          value: TunStack.gvisor,
          label: Text('gVisor', style: TextStyle(fontSize: 11)),
        ),
      ],
      selected: {current},
      onSelectionChanged: (sel) => onChanged(sel.first),
      showSelectedIcon: false,
    );
  }
}

// ── Log level menu ────────────────────────────────────────────────────────────

class _LogLevelMenu extends StatelessWidget {
  final LogLevel current;
  final ValueChanged<LogLevel> onChanged;
  final S s;
  const _LogLevelMenu({
    required this.current,
    required this.onChanged,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<LogLevel>(
      tooltip: s.logLevelTitle,
      initialValue: current,
      onSelected: onChanged,
      itemBuilder: (_) => LogLevel.values
          .map(
            (l) => PopupMenuItem(
              value: l,
              child: Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 8,
                    color: l == LogLevel.error
                        ? NexColors.error
                        : l == LogLevel.warn
                        ? NexColors.connecting
                        : cs.onSurface.withValues(alpha: 0.4),
                  ),
                  const SizedBox(width: 8),
                  Text(s.logLevelLabel(l.name)),
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
            Text(
              s.logLevelLabel(current.name),
              style: TextStyle(fontSize: 12, color: cs.onSurface),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

List<Widget> _groupSettings(BuildContext context, List<Widget> items) {
  final cs = Theme.of(context).colorScheme;
  final output = <Widget>[];
  final rows = <Widget>[];
  void flush() {
    if (rows.isEmpty) return;
    output.add(
      Material(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Divider(height: 0.5, indent: 40, color: cs.outlineVariant),
              rows[i],
            ],
          ],
        ),
      ),
    );
    rows.clear();
  }

  for (final item in items) {
    if (item is _SectionHeader) {
      flush();
      output.add(item);
    } else if (item is _SettingsNote) {
      flush();
      output.add(item);
    } else if (item is! Divider) {
      rows.add(item);
    }
  }
  flush();
  return output;
}
