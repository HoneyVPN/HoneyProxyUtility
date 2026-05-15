import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/app_theme.dart';
import '../../../../app/l10n/strings.dart';
import '../../domain/entities/connection_state.dart';

class ConnectButton extends ConsumerWidget {
  final ConnectionStatus status;
  final VoidCallback onTap;

  const ConnectButton({super.key, required this.status, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final isBusy = status == ConnectionStatus.connecting ||
        status == ConnectionStatus.preparing ||
        status == ConnectionStatus.disconnecting;

    final color = switch (status) {
      ConnectionStatus.connected    => NexColors.connected,
      ConnectionStatus.connecting   => NexColors.connecting,
      ConnectionStatus.preparing    => NexColors.connecting,
      ConnectionStatus.disconnecting => NexColors.connecting,
      ConnectionStatus.error        => NexColors.error,
      _                             => NexPalette.accent,
    };

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withOpacity(0.10),
          border: Border.all(color: color.withOpacity(0.55), width: 2),
          boxShadow: status == ConnectionStatus.connected
              ? [
                  BoxShadow(
                    color: color.withOpacity(0.28),
                    blurRadius: 32,
                    spreadRadius: 4,
                  ),
                ]
              : [],
        ),
        child: isBusy
            ? Center(
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    color: color,
                    strokeWidth: 2.5,
                  ),
                ),
              )
            : Center(
                child: Icon(
                  Icons.power_settings_new_rounded,
                  size: 36,
                  color: color,
                ),
              ),
      ),
    );
  }
}
