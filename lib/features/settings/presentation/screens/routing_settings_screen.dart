import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/app_theme.dart';
import '../../data/models/app_settings.dart';
import '../notifiers/settings_notifier.dart';

class RoutingSettingsScreen extends ConsumerWidget {
  const RoutingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider).value?.routingMode ?? RoutingMode.bypassRU;

    return Scaffold(
      appBar: AppBar(title: const Text('Routing Mode')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _InfoBanner(
            icon: Icons.info_outline,
            text: 'Routing mode controls which traffic goes through the proxy '
                'and which connects directly.',
          ),
          const SizedBox(height: 8),
          ...RoutingMode.values.map((m) => _RoutingTile(
            mode: m,
            selected: mode == m,
            onTap: () => ref.read(settingsProvider.notifier).setRouting(m),
          )),
        ],
      ),
    );
  }
}

class _RoutingTile extends StatelessWidget {
  final RoutingMode mode;
  final bool selected;
  final VoidCallback onTap;

  const _RoutingTile({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: selected ? cs.primaryContainer.withOpacity(0.35) : cs.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? cs.primary.withOpacity(0.45) : cs.outline.withOpacity(0.1),
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                Icon(_modeIcon(mode),
                    color: selected ? cs.primary : cs.onSurfaceVariant, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(mode.label,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: selected ? cs.primary : cs.onSurface,
                          )),
                      const SizedBox(height: 2),
                      Text(mode.description,
                          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
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

  IconData _modeIcon(RoutingMode m) => switch (m) {
    RoutingMode.global   => Icons.public,
    RoutingMode.bypassRU => Icons.flag_outlined,
    RoutingMode.rules    => Icons.rule_outlined,
  };
}

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoBanner({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
