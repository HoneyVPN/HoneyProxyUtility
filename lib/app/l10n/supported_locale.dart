import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Use the first supported system language; English is the fallback.
/// Saved application preferences always take precedence over this default.
String resolveAppLocale(Iterable<Locale> preferredLocales) {
  for (final locale in preferredLocales) {
    if (locale.languageCode == 'ru' || locale.languageCode == 'en') {
      return locale.languageCode;
    }
  }
  return 'en';
}

final systemLocaleProvider = Provider<String>(
  (ref) => resolveAppLocale(PlatformDispatcher.instance.locales),
);
