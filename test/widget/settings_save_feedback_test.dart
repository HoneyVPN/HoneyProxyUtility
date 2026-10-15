import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/dns_settings_screen.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/routing_settings_screen.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/settings_screen.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final locale in ['en', 'ru']) {
    for (final page in ['main', 'dns', 'routing']) {
      testWidgets('$locale $page save failure keeps selection and is handled', (
        tester,
      ) async {
        final strings = S(locale);
        final failing = _FailingSettings();
        final scope = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(() => failing),
            stringsProvider.overrideWithValue(strings),
            subscriptionsProvider.overrideWith(_EmptySubscriptions.new),
          ],
        );
        addTearDown(scope.dispose);
        await scope.read(settingsProvider.future);
        final screen = switch (page) {
          'dns' => const DnsSettingsScreen(),
          'routing' => const RoutingSettingsScreen(),
          _ => const SettingsScreen(),
        };
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: scope,
            child: MaterialApp(home: screen),
          ),
        );
        await tester.pumpAndSettle();
        if (page == 'main') {
          await tester.tap(find.byTooltip(strings.themeDark));
        } else if (page == 'dns') {
          await tester.tap(find.text('Google'));
        } else {
          await tester.tap(find.text(strings.routingModeLabel('global')));
        }
        await tester.pumpAndSettle();
        expect(failing.writes, 1);
        expect(find.text(strings.settingsSaveFailed), findsOneWidget);
        expect(
          scope.read(settingsProvider).requireValue.toJson(),
          const AppSettings().toJson(),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}

class _EmptySubscriptions extends SubscriptionsNotifier {
  @override
  Future<SubscriptionsState> build() async => const SubscriptionsState();
}

class _FailingSettings extends SettingsNotifier {
  int writes = 0;
  @override
  Future<AppSettings> build() async => const AppSettings();

  Future<void> _fail() async {
    writes++;
    throw const SettingsPersistenceException(storageUncertain: true);
  }

  @override
  Future<void> setTheme(ThemeMode value) => _fail();
  @override
  Future<void> setDns(DnsPreset preset, {String customUrl = ''}) => _fail();
  @override
  Future<void> setRouting(RoutingMode value) => _fail();
}
