import "dart:async";
import "dart:io" show Platform;

import "package:flutter/foundation.dart" show kIsWeb;

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_localizations/flutter_localizations.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "app_router.dart";
import "app_theme.dart";
import "import_links/import_link_listener.dart";
import "app_toast.dart";
import "android_notification_locale.dart";
import "windows_tray_controller.dart";
import "l10n/supported_locale.dart";
import "../features/settings/presentation/notifiers/settings_notifier.dart";
import "../features/diagnostics/presentation/diagnostic_auto_send_gate.dart";

class HoneyProxyApp extends ConsumerStatefulWidget {
  const HoneyProxyApp({super.key});

  @override
  ConsumerState<HoneyProxyApp> createState() => _HoneyProxyAppState();
}

class _HoneyProxyAppState extends ConsumerState<HoneyProxyApp> {
  static const _commandsChannel = MethodChannel("ru.honeyvpn.proxy/commands");
  ProviderSubscription<String>? _menuLocaleSubscription;
  WindowsTrayController? _windowsTray;
  AndroidNotificationLocaleController? _androidNotificationLocale;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isWindows) {
      _windowsTray = WindowsTrayController(
        container: ProviderScope.containerOf(context, listen: false),
        navigate: appRouter.go,
        showError: (message) {
          final overlayContext = appRouter
              .routerDelegate
              .navigatorKey
              .currentState
              ?.overlay
              ?.context;
          if (mounted && overlayContext != null && overlayContext.mounted) {
            AppToast.show(overlayContext, message);
          }
        },
      )..start();
    }
    if (!kIsWeb && Platform.isAndroid) {
      _androidNotificationLocale = AndroidNotificationLocaleController(
        ProviderScope.containerOf(context, listen: false),
      )..start();
    }
    if (!kIsWeb && Platform.isMacOS) {
      final systemLocale = ref.read(systemLocaleProvider);
      _commandsChannel.setMethodCallHandler((call) async {
        if (!mounted || call.method != 'navigate') return false;
        final route = call.arguments;
        if (route is! String ||
            !const {'/settings', '/converter'}.contains(route)) {
          return false;
        }
        appRouter.go(route);
        return true;
      });
      _menuLocaleSubscription = ref.listenManual<String>(
        settingsProvider.select<String>(
          (settings) => settings.value?.locale ?? systemLocale,
        ),
        (_, locale) {
          unawaited(
            _commandsChannel
                .invokeMethod<void>('setLocale', locale)
                .catchError((Object _) {}),
          );
        },
        fireImmediately: true,
      );
    }
  }

  @override
  void dispose() {
    _menuLocaleSubscription?.close();
    _androidNotificationLocale?.dispose();
    _windowsTray?.dispose();
    if (!kIsWeb && Platform.isMacOS) {
      _commandsChannel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final systemLocale = ref.watch(systemLocaleProvider);
    final themeMode = ref.watch(
      settingsProvider.select((s) => s.value?.themeMode ?? ThemeMode.system),
    );
    final locale = ref.watch(
      settingsProvider.select<String>((s) => s.value?.locale ?? systemLocale),
    );

    return ImportLinkListener(
      router: appRouter,
      child: MaterialApp.router(
        title: "Honey",
        theme: honeyThemeLight,
        darkTheme: honeyThemeDark,
        themeMode: themeMode,
        routerConfig: appRouter,
        builder: (context, child) => DiagnosticAutoSendGate(
          navigatorKey: appRouter.routerDelegate.navigatorKey,
          child: Theme(
            data: honeyThemeForWidth(
              Theme.of(context),
              MediaQuery.sizeOf(context).width,
            ),
            child: FocusTraversalGroup(
              policy: WidgetOrderTraversalPolicy(),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
        locale: Locale(locale),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale("en"), Locale("ru")],
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
