import "package:flutter/material.dart";
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../app/l10n/strings.dart';

class LatencyBadge extends ConsumerWidget {
  final double ms;
  const LatencyBadge({super.key, required this.ms});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ru = ref.watch(stringsProvider).locale == 'ru';
    final text = ms < 0 || !ms.isFinite
        ? '—'
        : '${ms.toStringAsFixed(0)} ${ru ? 'мс' : 'ms'}';
    final explanation = ms < 0 || !ms.isFinite
        ? (ru ? 'Не удалось измерить задержку' : 'Latency unavailable')
        : (ru ? 'Задержка соединения' : 'Connection latency');
    return Tooltip(
      message: explanation,
      excludeFromSemantics: true,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w400,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
