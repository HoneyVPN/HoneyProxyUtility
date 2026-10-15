import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/routing_settings_screen.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/models/subscription_model.dart';
import 'package:honeyproxyutility/features/subscriptions/domain/entities/provider_geo_state.dart';
import 'package:honeyproxyutility/features/subscriptions/presentation/screens/subscriptions_screen.dart';

class _Subs extends SubscriptionsNotifier {
  @override
  Future<SubscriptionsState> build() async => SubscriptionsState(
    subs: [
      SubscriptionModel(
        id: 17,
        url: 'https://provider.example.test/feed',
        name: 'Example VPN',
        updateIntervalHours: 3,
        lastUpdated: DateTime.now(),
        providerGeoStatus: ProviderGeoStatus.unavailable,
        providerGeoIssue: ProviderGeoIssue.tooLarge,
      ),
    ],
  );
}

class _Servers extends ServersNotifier {
  @override
  Future<List<ServerProfileModel>> build() async => [];
}

Future<ProviderContainer> _render(
  WidgetTester tester,
  String locale, {
  bool subscriptions = false,
  RoutingMode routing = RoutingMode.bypassRU,
}) async {
  SharedPreferences.setMockInitialValues({
    'honeyvpn_settings': AppSettings(
      locale: locale,
      routingMode: routing,
      dnsPreset: DnsPreset.custom,
      customDnsUrl: 'https://dns.example.test/query',
    ).toJsonString(),
  });
  final container = ProviderContainer(
    overrides: [
      subscriptionsProvider.overrideWith(_Subs.new),
      serversNotifierProvider.overrideWith(_Servers.new),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  await container.read(subscriptionsProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: honeyThemeLight,
        home: subscriptions
            ? const SubscriptionsScreen()
            : const RoutingSettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  for (final locale in ['ru', 'en']) {
    testWidgets(
      'geo routing mode persists without rewriting DNS or provider unavailable state in $locale',
      (tester) async {
        final container = await _render(tester, locale);
        final s = S(locale);
        expect(find.text(s.geoRoutingBuiltIn), findsOneWidget);
        expect(find.text(s.geoRoutingProvider), findsOneWidget);
        expect(find.text(s.geoRoutingCombined), findsOneWidget);
        expect(
          find.text(s.providerGeoFailure(ProviderGeoIssue.tooLarge)),
          findsOneWidget,
        );
        await tester.tap(find.text(s.geoRoutingCombined));
        await tester.pumpAndSettle();
        final setting = container.read(settingsProvider).requireValue;
        expect(setting.geoRoutingMode, GeoRoutingMode.combined);
        expect(setting.dnsPreset, DnsPreset.custom);
        expect(setting.customDnsUrl, 'https://dns.example.test/query');
        final prefs = await SharedPreferences.getInstance();
        expect(
          AppSettings.fromJsonString(
            prefs.getString('honeyvpn_settings')!,
          ).geoRoutingMode,
          GeoRoutingMode.combined,
        );
        expect(
          container
              .read(subscriptionsProvider)
              .requireValue
              .subs
              .single
              .providerGeoStatus,
          ProviderGeoStatus.unavailable,
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('global routing disables all geo mode actions in $locale', (
      tester,
    ) async {
      final container = await _render(
        tester,
        locale,
        routing: RoutingMode.global,
      );
      final tiles = tester.widgetList<RadioListTile<GeoRoutingMode>>(
        find.byType(RadioListTile<GeoRoutingMode>),
      );
      expect(tiles, hasLength(3));
      expect(tiles.every((t) => t.enabled == false), true);
      await tester.tap(
        find.descendant(
          of: find.byType(RadioListTile<GeoRoutingMode>),
          matching: find.text(S(locale).geoRoutingProvider),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).requireValue.geoRoutingMode,
        GeoRoutingMode.builtIn,
      );
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'subscription warning explains too-large geo and provider three-hour interval remains selectable in $locale',
      (tester) async {
        await _render(tester, locale, subscriptions: true);
        final s = S(locale);
        expect(
          find.byTooltip(s.providerGeoFailure(ProviderGeoIssue.tooLarge)),
          findsOneWidget,
        );
        final warning = tester.widget<Icon>(find.byIcon(Icons.warning_rounded));
        expect(warning.color, NexColors.warningFor(Brightness.light));
        await tester.tap(
          find.byTooltip(
            locale == 'ru' ? 'Период обновления' : 'Auto-update interval',
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(locale == 'ru' ? 'Каждые 3 ч' : 'Every 3h'),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
