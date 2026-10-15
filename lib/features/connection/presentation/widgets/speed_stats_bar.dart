import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n/strings.dart';
import '../../domain/entities/connection_state.dart';

class SpeedStatsBar extends ConsumerWidget {
  final VpnStats stats;
  const SpeedStatsBar({super.key, required this.stats});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final s = ref.watch(stringsProvider);
    final ru = s.locale == 'ru';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      child: Row(
        children: [
          Expanded(
            child: _StatItem(
              icon: Icons.south_rounded,
              label: stats.ratesAvailable
                  ? _formatSpeed(stats.downloadSpeed, ru)
                  : '—',
              semanticValue: stats.ratesAvailable ? null : s.statsUnavailable,
              sublabel: ru ? 'Скорость получения' : 'Download speed',
              color: cs.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: _StatItem(
              icon: Icons.north_rounded,
              label: stats.ratesAvailable
                  ? _formatSpeed(stats.uploadSpeed, ru)
                  : '—',
              semanticValue: stats.ratesAvailable ? null : s.statsUnavailable,
              sublabel: ru ? 'Скорость отправки' : 'Upload speed',
              color: cs.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: _StatItem(
              icon: Icons.schedule_rounded,
              label: _formatDuration(stats.sessionDuration),
              sublabel: ru ? 'Время подключения' : 'Connection duration',
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatSpeed(double bytesPerSec, bool ru) {
    final speed = bytesPerSec.isFinite && bytesPerSec > 0 ? bytesPerSec : 0.0;
    if (speed >= 1024 * 1024) {
      return '${(speed / 1024 / 1024).toStringAsFixed(1)} ${ru ? 'МБ/с' : 'MB/s'}';
    }
    if (speed >= 1024)
      return '${(speed / 1024).toStringAsFixed(0)} ${ru ? 'КБ/с' : 'KB/s'}';
    return '${speed.toStringAsFixed(0)} ${ru ? 'Б/с' : 'B/s'}';
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return d.inHours == 0 ? '$m:$s' : '$h:$m:$s';
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final Color color;
  final String? semanticValue;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.color,
    this.semanticValue,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: sublabel,
      value: semanticValue ?? label,
      child: Tooltip(
        message: semanticValue == null ? sublabel : '$sublabel: $semanticValue',
        excludeFromSemantics: true,
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: color, size: 14),
                const SizedBox(width: 5),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
