import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Lightweight overlay toast that always auto-dismisses after [duration].
/// Uses a global OverlayEntry so it survives screen navigation and works
/// reliably on Windows desktop (no ScaffoldMessenger / SnackBar timer bugs).
class AppToast {
  AppToast._();

  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _dismiss();

    final overlay = Navigator.of(context, rootNavigator: true).overlay;
    if (overlay == null) return;

    // Toast always uses dark surface — works on both light and dark themes,
    // avoids theme detection issues with OverlayEntry context.
    const bg  = NexPalette.darkSurface2;
    const fg  = NexPalette.darkOnSurface;
    const act = NexPalette.accent;

    _entry = OverlayEntry(
      builder: (_) => _ToastOverlay(
        message: message,
        actionLabel: actionLabel,
        onAction: () { _dismiss(); onAction?.call(); },
        bg: bg,
        fg: fg,
        act: act,
      ),
    );

    overlay.insert(_entry!);
    _timer = Timer(duration, _dismiss);
  }

  static void _dismiss() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _ToastOverlay extends StatelessWidget {
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color bg;
  final Color fg;
  final Color act;

  const _ToastOverlay({
    required this.message,
    required this.bg,
    required this.fg,
    required this.act,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {

    // Position above the bottom nav bar (nav ~76px + 12px padding)
    return Positioned(
      left: 16,
      right: 16,
      bottom: 100,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 12, offset: const Offset(0, 4)),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(message,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onAction,
                  child: Text(actionLabel!,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: act,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
