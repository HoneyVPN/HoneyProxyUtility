import 'package:flutter/material.dart';

import '../../domain/entities/connection_state.dart';

class SpeedStatsBar extends StatelessWidget {
  final VpnStats stats;
  const SpeedStatsBar({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _StatItem(
            icon: Icons.arrow_upward,
            label: _formatSpeed(stats.uploadSpeed),
            sublabel: 'Upload',
            color: Colors.blue,
          ),
          Container(width: 1, height: 40, color: cs.outline.withOpacity(0.3)),
          _StatItem(
            icon: Icons.arrow_downward,
            label: _formatSpeed(stats.downloadSpeed),
            sublabel: 'Download',
            color: Colors.green,
          ),
          Container(width: 1, height: 40, color: cs.outline.withOpacity(0.3)),
          _StatItem(
            icon: Icons.timer_outlined,
            label: _formatDuration(stats.sessionDuration),
            sublabel: 'Session',
            color: Colors.orange,
          ),
        ],
      ),
    );
  }

  static String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec >= 1024 * 1024) {
      return '${(bytesPerSec / 1024 / 1024).toStringAsFixed(1)} MB/s';
    } else if (bytesPerSec >= 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${bytesPerSec.toStringAsFixed(0)} B/s';
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final Color color;

  const _StatItem({required this.icon, required this.label, required this.sublabel, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        Text(sublabel, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6))),
      ],
    );
  }
}
