import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoActivityIndicator, CupertinoIcons;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/l10n/strings.dart';
import '../../domain/entities/connection_state.dart';

/// A generous primary control; the framework owns its keyboard and VoiceOver
/// action. State feedback stays inside the control instead of outlining cards.
class ConnectButton extends ConsumerWidget {
  final ConnectionStatus status;
  final VoidCallback onTap;
  final bool enabled;
  final double diameter;
  const ConnectButton({
    super.key,
    required this.status,
    required this.onTap,
    this.enabled = true,
    this.diameter = 160,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final cs = Theme.of(context).colorScheme;
    final busy =
        status == ConnectionStatus.connecting ||
        status == ConnectionStatus.preparing ||
        status == ConnectionStatus.disconnecting;
    final connected = status == ConnectionStatus.connected;
    final label = switch (status) {
      ConnectionStatus.connected => s.disconnect,
      ConnectionStatus.connecting => s.connecting,
      ConnectionStatus.preparing => s.preparing,
      ConnectionStatus.disconnecting => s.disconnecting,
      ConnectionStatus.error => s.retry,
      _ => s.connect,
    };
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final extent = diameter + (scale > 1.5 ? 24.0 : 0.0);
    final compact = extent < 160;
    final large = diameter > 160;
    final dark = cs.brightness == Brightness.dark;
    final foreground = cs.onSurface;
    final statusLabel = switch (status) {
      ConnectionStatus.connected => s.statusConnected,
      ConnectionStatus.connecting => s.statusConnecting,
      ConnectionStatus.preparing => s.statusPreparing,
      ConnectionStatus.disconnecting => s.statusDisconnecting,
      ConnectionStatus.error => s.statusError,
      _ => s.statusDisconnected,
    };
    return SizedBox(
      key: const ValueKey('primary-connect-control'),
      width: extent,
      height: extent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [cs.surface, cs.surfaceContainer],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.18 : 0.045),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Semantics(
          container: true,
          liveRegion: true,
          value: statusLabel,
          child: FilledButton(
            onPressed: enabled && !busy ? onTap : null,
            style: ButtonStyle(
              backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? cs.onSurfaceVariant
                    : foreground,
              ),
              shape: WidgetStateProperty.resolveWith(
                (states) => CircleBorder(
                  side: states.contains(WidgetState.focused)
                      ? BorderSide(color: cs.primary, width: 2)
                      : BorderSide.none,
                ),
              ),
              padding: WidgetStatePropertyAll(
                EdgeInsets.all(compact ? 12 : 18),
              ),
              elevation: WidgetStateProperty.resolveWith(
                (states) =>
                    states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.focused)
                    ? 1
                    : 0,
              ),
              shadowColor: WidgetStatePropertyAll(
                Colors.black.withValues(alpha: 0.12),
              ),
              surfaceTintColor: const WidgetStatePropertyAll(
                Colors.transparent,
              ),
              overlayColor: WidgetStatePropertyAll(
                cs.primary.withValues(alpha: 0.08),
              ),
              textStyle: WidgetStatePropertyAll(
                Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontSize: large ? 14 : 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  CupertinoActivityIndicator(
                    radius: large ? 18 : 16,
                    color: cs.onSurfaceVariant,
                  )
                else
                  Icon(
                    CupertinoIcons.power,
                    size: large
                        ? 48
                        : compact
                        ? 32
                        : 40,
                    color: enabled
                        ? (connected ? cs.tertiary : cs.primary)
                        : cs.onSurfaceVariant,
                  ),
                SizedBox(height: compact ? 6 : 11),
                Text(label, textAlign: TextAlign.center, maxLines: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
