import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/app/l10n/supported_locale.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final locale in ['ru', 'en']) {
    test(
      'first launch uses the system $locale language before and after loading',
      () async {
        final preferredLocales = [Locale(locale, locale == 'ru' ? 'RU' : 'GB')];
        final container = ProviderContainer(
          overrides: [
            systemLocaleProvider.overrideWithValue(
              resolveAppLocale(preferredLocales),
            ),
          ],
        );
        addTearDown(container.dispose);
        expect(container.read(stringsProvider).locale, locale);
        expect((await container.read(settingsProvider.future)).locale, locale);
        expect(container.read(stringsProvider).locale, locale);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('honeyvpn_settings'), isFalse);
      },
    );
  }

  test(
    'first supported preferred language is used with English fallback',
    () async {
      final preferredLocales = [
        const Locale('de'),
        const Locale('ru'),
        const Locale('en'),
      ];
      var container = ProviderContainer(
        overrides: [
          systemLocaleProvider.overrideWithValue(
            resolveAppLocale(preferredLocales),
          ),
        ],
      );
      expect((await container.read(settingsProvider.future)).locale, 'ru');
      container.dispose();
      container = ProviderContainer(
        overrides: [
          systemLocaleProvider.overrideWithValue(
            resolveAppLocale([const Locale('ja')]),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect((await container.read(settingsProvider.future)).locale, 'en');
    },
  );

  for (final savedLocale in ['ru', 'en']) {
    test(
      'saved $savedLocale selection survives a different system language and restart',
      () async {
        final preferredLocales = [Locale(savedLocale == 'ru' ? 'en' : 'ru')];
        SharedPreferences.setMockInitialValues({
          'honeyvpn_settings': AppSettings(locale: savedLocale).toJsonString(),
        });
        var container = ProviderContainer(
          overrides: [
            systemLocaleProvider.overrideWithValue(
              resolveAppLocale(preferredLocales),
            ),
          ],
        );
        expect(
          (await container.read(settingsProvider.future)).locale,
          savedLocale,
        );
        final selected = savedLocale == 'ru' ? 'en' : 'ru';
        await container.read(settingsProvider.notifier).setLocale(selected);
        expect(container.read(stringsProvider).locale, selected);
        container.dispose();
        container = ProviderContainer(
          overrides: [
            systemLocaleProvider.overrideWithValue(
              resolveAppLocale([Locale(savedLocale)]),
            ),
          ],
        );
        addTearDown(container.dispose);
        expect(
          (await container.read(settingsProvider.future)).locale,
          selected,
        );
        expect(container.read(stringsProvider).locale, selected);
      },
    );
  }
}
