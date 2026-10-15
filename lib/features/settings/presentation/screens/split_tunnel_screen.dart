import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n/strings.dart';

/// Kept for existing routes; no platform implements a per-app picker yet.
class SplitTunnelScreen extends ConsumerWidget {
  const SplitTunnelScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(strings.splitTunnelTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              strings.splitTunnelSubtitle,
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
            ),
          ),
        ),
      ),
    );
  }
}
