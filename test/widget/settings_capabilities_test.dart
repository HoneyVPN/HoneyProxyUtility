import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/settings_screen.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/log_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'HoneyProxyUtility',
      packageName: 'ru.honeyvpn.proxy',
      version: '1.2.0',
      buildNumber: '124',
      buildSignature: '',
    );
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final locale in ['ru', 'en']) {
    testWidgets('Android does not offer unsupported controls in $locale', (
      tester,
    ) async {
      try {
        await _render(tester, platform: TargetPlatform.android, locale: locale);
        final strings = S(locale);
        expect(find.text(strings.fakeipTitle), findsNothing);
        expect(find.text(strings.splitTunnelTitle), findsNothing);
        expect(find.text(strings.tunStackTitle), findsNothing);
        expect(find.byType(SegmentedButton<ConnectionMode>), findsNothing);
        expect(find.byType(SegmentedButton<TunStack>), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  testWidgets('Windows tunnel retains usable TUN stack selection', (
    tester,
  ) async {
    try {
      final container = await _render(
        tester,
        platform: TargetPlatform.windows,
        locale: 'en',
      );
      final selector = find.byType(SegmentedButton<TunStack>);
      expect(selector, findsOneWidget);
      const strings = S('en');
      expect(find.text(strings.portsTitle), findsNothing);
      expect(find.text(strings.allowLanTitle), findsNothing);
      expect(find.text(strings.logLevelTitle), findsNothing);
      await tester.tap(
        find.descendant(of: selector, matching: find.text('gVisor')),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).requireValue.tunStack,
        TunStack.gvisor,
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('Windows proxy mode does not offer an ineffective TUN selector', (
    tester,
  ) async {
    try {
      await _render(
        tester,
        platform: TargetPlatform.windows,
        locale: 'ru',
        mode: ConnectionMode.proxy,
      );
      expect(find.byType(SegmentedButton<TunStack>), findsNothing);
      expect(find.text(const S('ru').tunStackTitle), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
  testWidgets(
    'Mac offers VPN mode recovery and omits unavailable LAN sharing',
    (tester) async {
      try {
        final container = await _render(
          tester,
          platform: TargetPlatform.macOS,
          locale: 'en',
          mode: ConnectionMode.proxy,
        );
        final strings = const S('en');
        expect(find.byType(SegmentedButton<ConnectionMode>), findsNothing);
        expect(find.text(strings.appleProxyModeSaved), findsOneWidget);
        await tester.tap(find.text(strings.useVpnTunnel));
        await tester.pumpAndSettle();
        expect(
          container.read(settingsProvider).requireValue.connectionMode,
          ConnectionMode.tunnel,
        );
        expect(find.text(strings.appleProxyModeSaved), findsNothing);
        expect(
          find.byKey(ValueKey('setting-switch-${strings.allowLanTitle}')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets('Russian proxy settings display the saved SOCKS and HTTP ports', (
    tester,
  ) async {
    try {
      await _render(
        tester,
        platform: TargetPlatform.windows,
        locale: 'ru',
        mode: ConnectionMode.proxy,
        socksPort: 8123,
        httpPort: 8124,
      );
      expect(
        find.text('SOCKS5 127.0.0.1:8123 · HTTP 127.0.0.1:8124'),
        findsOneWidget,
      );
      expect(find.textContaining('localhost:2080'), findsNothing);
      expect(find.text('Россия напрямую'), findsOneWidget);
      expect(find.textContaining('RU & .ru'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  for (final width in [360.0, 1000.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('settings rows stay centered at width $width, scale $scale', (
        tester,
      ) async {
        try {
          await _render(tester, platform: TargetPlatform.windows, locale: 'ru');
          tester.view.physicalSize = Size(width, 2400);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpAndSettle();
          const strings = S('ru');
          for (final title in [strings.logsTitle, strings.urlSchemesTitle]) {
            final row = find.byKey(ValueKey('settings-row-$title'));
            await tester.ensureVisible(row);
            await tester.pumpAndSettle();
            final bounds = tester.getRect(row);
            expect(
              tester.getRect(find.text(title)).center.dy,
              closeTo(bounds.center.dy, 0.5),
              reason: title,
            );
            final icon = find
                .descendant(of: row, matching: find.byType(Icon))
                .first;
            expect(
              tester.getRect(icon).center.dy,
              closeTo(bounds.center.dy, 0.5),
            );
          }
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
          await tester.pumpWidget(const SizedBox.shrink());
        }
      });
    }
  }

  testWidgets(
    'reserved controller port is rejected without changing settings',
    (tester) async {
      try {
        final container = await _render(
          tester,
          platform: TargetPlatform.windows,
          locale: 'ru',
          mode: ConnectionMode.proxy,
        );
        const strings = S('ru');
        await tester.tap(find.text(strings.portsTitle));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '9090');
        await tester.tap(find.text(strings.saveButton));
        await tester.pumpAndSettle();
        expect(find.text(strings.invalidPorts), findsOneWidget);
        expect(container.read(settingsProvider).requireValue.socksPort, 2080);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('Windows log view does not offer a stale core log file', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [stringsProvider.overrideWithValue(const S('en'))],
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Core log'), findsNothing);
      expect(find.text('Connection events will appear here.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}

Future<ProviderContainer> _render(
  WidgetTester tester, {
  required TargetPlatform platform,
  required String locale,
  ConnectionMode mode = ConnectionMode.tunnel,
  int socksPort = 2080,
  int httpPort = 2081,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({
    'honeyvpn_settings': AppSettings(
      locale: locale,
      connectionMode: mode,
      socksPort: socksPort,
      httpPort: httpPort,
    ).toJsonString(),
  });
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: SettingsScreen())),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(SettingsScreen)));
}
