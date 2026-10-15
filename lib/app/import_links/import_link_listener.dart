import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app_toast.dart';
import '../l10n/strings.dart';
import 'import_link.dart';

final importLinkEventsProvider = Provider<Stream<dynamic>>((ref) {
  if (kIsWeb ||
      !(Platform.isAndroid ||
          Platform.isMacOS ||
          Platform.isWindows ||
          Platform.isIOS)) {
    return const Stream.empty();
  }
  return const EventChannel(
    'ru.honeyvpn.proxy/deeplink',
  ).receiveBroadcastStream();
});

/// Navigation occurs after a frame, including links delivered during startup.
class ImportLinkListener extends ConsumerStatefulWidget {
  const ImportLinkListener({
    super.key,
    required this.router,
    required this.child,
  });
  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<ImportLinkListener> createState() => _ImportLinkListenerState();
}

class _ImportLinkListenerState extends ConsumerState<ImportLinkListener> {
  static int _activationSerial = 0;
  final _inbox = ImportLinkInbox();
  StreamSubscription<dynamic>? _subscription;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _subscription = ref
        .read(importLinkEventsProvider)
        .listen(
          (event) {
            if (_inbox.receive(event)) _schedule();
          },
          onError: (Object error) {
            _inbox.fail(
              error is PlatformException && error.code == 'IMPORT_LINK_TOO_LONG'
                  ? ImportLinkFailure.tooLong
                  : ImportLinkFailure.unavailable,
            );
            _schedule();
          },
        );
  }

  void _schedule() {
    if (!mounted || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final pending = _inbox.take();
      if (pending is ImportLink) {
        widget.router.go(
          '${pending.location}&importActivation=${++_activationSerial}',
        );
      } else if (pending is ImportLinkFailure) {
        final context = widget
            .router
            .routerDelegate
            .navigatorKey
            .currentState
            ?.overlay
            ?.context;
        if (context == null || !context.mounted) return;
        final strings = ref.read(stringsProvider);
        final message = switch (pending) {
          ImportLinkFailure.invalid => strings.importLinkInvalid,
          ImportLinkFailure.tooLong => strings.importLinkTooLong,
          ImportLinkFailure.unsupportedSource => strings.importLinkUnsupported,
          ImportLinkFailure.unavailable => strings.importLinkUnavailable,
        };
        AppToast.show(context, message);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _inbox.close();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
