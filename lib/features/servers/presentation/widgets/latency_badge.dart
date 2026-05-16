import "package:flutter/material.dart";
import "../../../../app/app_theme.dart";

class LatencyBadge extends StatelessWidget {
  final double ms;
  const LatencyBadge({super.key, required this.ms});

  @override
  Widget build(BuildContext context) {
    if (ms < 0) {
      return const SizedBox(
        width: 44,
        child: Center(
          child: Text(
            "N/A",
            style: TextStyle(
              fontSize: 11,
              color: Color(0xFF888888),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    final color = ms < 100
        ? NexColors.connected
        : ms < 300
            ? NexColors.connecting
            : NexColors.error;

    return Container(
      constraints: const BoxConstraints(minWidth: 44),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        "${ms.toStringAsFixed(0)}ms",
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
