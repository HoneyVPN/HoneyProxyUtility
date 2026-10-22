import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n/strings.dart';
import '../notifiers/servers_notifier.dart';

/// A compact toolbar action, with progress and cancellation in the same place.
class LatencyTestAction extends ConsumerWidget {
  const LatencyTestAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    final progress = ref.watch(latencyTestProgressProvider);
    final enabled = ref.watch(
      serversNotifierProvider.select(
        (servers) => servers.value?.isNotEmpty == true,
      ),
    );
    final desktop = MediaQuery.sizeOf(context).width >= 700;
    final colors = Theme.of(context).colorScheme;
    final running = progress.isRunning;
    final tooltip = running
        ? strings.cancelLatencyTest
        : strings.pingAllTooltip;
    return MergeSemantics(
      key: const ValueKey('check-server-latency'),
      child: Semantics(
        liveRegion: running,
        value: running
            ? strings.latencyProgress(progress.completed, progress.total)
            : null,
        child: IconButton(
          tooltip: tooltip,
          onPressed: enabled
              ? () {
                  final notifier = ref.read(serversNotifierProvider.notifier);
                  if (running) {
                    notifier.cancelLatencyTests();
                  } else {
                    notifier.testAllLatency();
                  }
                }
              : null,
          style: IconButton.styleFrom(
            minimumSize: Size.square(desktop ? 36 : 44),
            padding: const EdgeInsets.all(8),
            foregroundColor: colors.onSurfaceVariant,
          ),
          icon: ExcludeSemantics(
            child: running
                ? RepaintBoundary(
                    child: SizedBox.square(
                      dimension: 20,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Keep moving between results too; numeric progress
                          // is exposed above through the live semantics value.
                          CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: colors.primary,
                            backgroundColor: colors.onSurface.withValues(
                              alpha: 0.08,
                            ),
                          ),
                          Icon(
                            CupertinoIcons.stop_fill,
                            size: 7,
                            color: colors.primary,
                          ),
                        ],
                      ),
                    ),
                  )
                : const Icon(CupertinoIcons.speedometer, size: 20),
          ),
        ),
      ),
    );
  }
}
