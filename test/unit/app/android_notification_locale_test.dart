import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:honeyproxyutility/app/android_notification_locale.dart';
import 'package:honeyproxyutility/app/l10n/supported_locale.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ru.honeyvpn.proxy/vpn');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final locale in ['ru', 'en']) {
    test(
      '$locale notification follows settings without any VPN command',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
        final container = ProviderContainer(
          overrides: [systemLocaleProvider.overrideWithValue(locale)],
        );
        addTearDown(container.dispose);
        final controller = AndroidNotificationLocaleController(container)
          ..start();
        addTearDown(controller.dispose);
        await container.read(settingsProvider.future);
        await Future<void>.delayed(Duration.zero);
        expect(calls.map((call) => call.method), ['setLocale']);
        expect(calls.single.arguments, {'locale': locale});
        controller.start();
        final settings = container.read(settingsProvider.notifier);
        await settings.setTheme(ThemeMode.dark);
        await settings.setPorts(12080, 12081);
        await settings.setLocale(locale);
        await Future<void>.delayed(Duration.zero);
        expect(calls, hasLength(1));
        final other = locale == 'ru' ? 'en' : 'ru';
        await settings.setLocale(other);
        await Future<void>.delayed(Duration.zero);
        expect(calls.map((call) => call.method), ['setLocale', 'setLocale']);
        expect(calls.last.arguments, {'locale': other});
        controller.dispose();
        await settings.setLocale(locale);
        await Future<void>.delayed(Duration.zero);
        expect(calls, hasLength(2));
      },
    );
  }

  test(
    'saved language replaces system fallback without reconnecting',
    () async {
      SharedPreferences.setMockInitialValues({
        'honeyvpn_settings': const AppSettings(locale: 'ru').toJsonString(),
      });
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return false; // No active native service is also a valid no-op.
      });
      final container = ProviderContainer(
        overrides: [systemLocaleProvider.overrideWithValue('en')],
      );
      addTearDown(container.dispose);
      final controller = AndroidNotificationLocaleController(container)
        ..start();
      addTearDown(controller.dispose);
      await container.read(settingsProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((call) => call.method), ['setLocale', 'setLocale']);
      expect(calls.map((call) => call.arguments), [
        {'locale': 'en'},
        {'locale': 'ru'},
      ]);
      expect(container.read(settingsProvider).requireValue.locale, 'ru');
    },
  );

  test(
    'notification channel failure cannot undo or block a saved language',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'notification_unavailable');
      });
      final container = ProviderContainer(
        overrides: [systemLocaleProvider.overrideWithValue('en')],
      );
      addTearDown(container.dispose);
      final controller = AndroidNotificationLocaleController(container)
        ..start();
      addTearDown(controller.dispose);
      await container.read(settingsProvider.future);
      await container.read(settingsProvider.notifier).setLocale('ru');
      await Future<void>.delayed(Duration.zero);
      expect(container.read(settingsProvider).requireValue.locale, 'ru');
      final prefs = await SharedPreferences.getInstance();
      expect(
        AppSettings.fromJsonString(
          prefs.getString('honeyvpn_settings')!,
        ).locale,
        'ru',
      );
    },
  );
}
