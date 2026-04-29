import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_router.dart';
import 'app_theme.dart';
import '../features/settings/presentation/notifiers/settings_notifier.dart';

class HoneyProxyApp extends ConsumerWidget {
  const HoneyProxyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(
      settingsProvider.select((s) => s.value?.themeMode ?? ThemeMode.system),
    );
    final locale = ref.watch(
      settingsProvider.select((s) => s.value?.locale ?? 'en'),
    );

    return MaterialApp.router(
      title: 'Honey',
      theme: honeyThemeLight,
      darkTheme: honeyThemeDark,
      themeMode: themeMode,
      routerConfig: appRouter,
      locale: Locale(locale),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'),
        Locale('ru'),
      ],
      debugShowCheckedModeBanner: false,
    );
  }
}
