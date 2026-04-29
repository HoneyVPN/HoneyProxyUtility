import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/app_theme.dart';
import '../../data/models/app_settings.dart';
import '../notifiers/settings_notifier.dart';

class DnsSettingsScreen extends ConsumerStatefulWidget {
  const DnsSettingsScreen({super.key});

  @override
  ConsumerState<DnsSettingsScreen> createState() => _DnsSettingsScreenState();
}

class _DnsSettingsScreenState extends ConsumerState<DnsSettingsScreen> {
  late TextEditingController _customCtrl;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider).value ?? const AppSettings();
    _customCtrl = TextEditingController(text: settings.customDnsUrl);
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value ?? const AppSettings();
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('DNS Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // Info
          _InfoCard(
            'DNS-over-HTTPS (DoH) encrypts your DNS queries, '
            'preventing ISPs from seeing which sites you visit.',
          ),

          const _SectionLabel('DNS Provider'),
          ...DnsPreset.values.map((preset) => _DnsTile(
            preset: preset,
            selected: settings.dnsPreset == preset,
            onTap: () => ref.read(settingsProvider.notifier).setDns(
              preset,
              customUrl: preset == DnsPreset.custom ? _customCtrl.text : '',
            ),
          )),

          // Custom URL field — visible only when Custom selected
          if (settings.dnsPreset == DnsPreset.custom)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Custom DoH URL',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _customCtrl,
                    decoration: const InputDecoration(
                      hintText: 'https://your-doh-server.com/dns-query',
                    ),
                    onSubmitted: (v) => ref
                        .read(settingsProvider.notifier)
                        .setDns(DnsPreset.custom, customUrl: v.trim()),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () => ref
                        .read(settingsProvider.notifier)
                        .setDns(DnsPreset.custom, customUrl: _customCtrl.text.trim()),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),

          const Divider(height: 24),
          const _SectionLabel('How it works'),
          _InfoCard(
            '• Remote DNS: resolves via DoH through your proxy server\n'
            '• Local DNS: system resolver used for bypass/direct traffic\n'
            '• Fake-IP: fast, low-latency mode — returns virtual IPs (recommended)',
          ),
        ],
      ),
    );
  }
}

class _DnsTile extends StatelessWidget {
  final DnsPreset preset;
  final bool selected;
  final VoidCallback onTap;

  const _DnsTile({required this.preset, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: selected ? cs.primaryContainer.withOpacity(0.3) : cs.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? cs.primary.withOpacity(0.45) : cs.outline.withOpacity(0.1),
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: _color(preset).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(
                      preset == DnsPreset.custom ? '?' : preset.ip,
                      style: TextStyle(
                        fontSize: preset == DnsPreset.custom ? 18 : 10,
                        fontWeight: FontWeight.w700,
                        color: _color(preset),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(preset.label,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: selected ? cs.primary : cs.onSurface,
                          )),
                      if (preset != DnsPreset.custom)
                        Text(preset.serverUrl,
                            style: TextStyle(
                                fontSize: 11, color: cs.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle, color: NexColors.connected, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _color(DnsPreset p) => switch (p) {
    DnsPreset.cloudflare => const Color(0xFFF48120),
    DnsPreset.google     => const Color(0xFF4285F4),
    DnsPreset.adguard    => const Color(0xFF67B346),
    DnsPreset.custom     => NexPalette.accent,
  };
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.9,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _InfoCard extends StatelessWidget {
  final String text;
  const _InfoCard(this.text);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
    );
  }
}
