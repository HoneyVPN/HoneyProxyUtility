import 'package:flutter/material.dart';

import '../../../../app/app_theme.dart';

class SplitTunnelScreen extends StatelessWidget {
  const SplitTunnelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Split Tunneling')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // What is it
          _Card(
            icon: Icons.call_split_outlined,
            iconColor: NexPalette.accent,
            title: 'What is Split Tunneling?',
            body: 'Split tunneling lets you choose which apps or traffic '
                'routes through the VPN and which connects directly to the internet.\n\n'
                'Example: route your browser through the proxy but let your bank '
                'app connect directly.',
          ),
          const SizedBox(height: 12),

          // Two modes
          _Card(
            icon: Icons.check_circle_outline,
            iconColor: NexColors.connected,
            title: 'Include mode',
            body: 'Only selected apps use the VPN tunnel.\n'
                'Everything else connects directly. Good for specific use cases.',
          ),
          const SizedBox(height: 8),
          _Card(
            icon: Icons.block_outlined,
            iconColor: NexColors.error,
            title: 'Exclude mode',
            body: 'All apps use the VPN except the ones you exclude.\n'
                'Useful for allowing trusted apps to bypass the tunnel.',
          ),
          const SizedBox(height: 16),

          // Platform availability
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.outline.withOpacity(0.15)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Platform support',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, color: cs.onSurface)),
                const SizedBox(height: 10),
                _PlatformRow(Icons.android, 'Android',
                    'Full per-app support via VpnService', NexColors.connected),
                _PlatformRow(Icons.apple, 'iOS / macOS',
                    'Per-app support via Network Extension', NexColors.connected),
                _PlatformRow(Icons.desktop_windows, 'Windows / Linux',
                    'IP/domain rule-based only', NexColors.connecting),
                _PlatformRow(Icons.language, 'Web demo',
                    'Not applicable (proxy mode only)', cs.onSurfaceVariant),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: NexColors.connecting.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: NexColors.connecting.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.construction_outlined,
                    color: NexColors.connecting, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Per-app split tunneling is coming in a future update '
                    'for mobile. Currently routing rules (bypass RU/CN) '
                    'provide domain-level control.',
                    style: TextStyle(
                        fontSize: 13, color: NexColors.connecting),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;

  const _Card({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outline.withOpacity(0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 6),
                Text(body,
                    style: TextStyle(
                        fontSize: 13, color: cs.onSurfaceVariant, height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlatformRow extends StatelessWidget {
  final IconData icon;
  final String platform;
  final String status;
  final Color color;

  const _PlatformRow(this.icon, this.platform, this.status, this.color);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        SizedBox(
            width: 80,
            child: Text(platform,
                style: const TextStyle(fontWeight: FontWeight.w500,
                    fontSize: 13))),
        Expanded(
          child: Text(status,
              style: TextStyle(fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ],
    ),
  );
}
