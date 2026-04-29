import 'package:flutter/material.dart';
import '../../../../app/app_theme.dart';

class LatencyBadge extends StatelessWidget {
  final double ms;
  const LatencyBadge({super.key, required this.ms});

  @override
  Widget build(BuildContext context) {
    if (ms < 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: NexColors.error.withOpacity(0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text(
          'timeout',
          style: TextStyle(fontSize: 11, color: NexColors.error, fontWeight: FontWeight.w600),
        ),
      );
    }

    final color = ms < 100
        ? NexColors.connected
        : ms < 300
            ? NexColors.connecting
            : NexColors.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${ms.toStringAsFixed(0)}ms',
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
