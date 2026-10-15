import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/converter/presentation/screens/converter_screen.dart';
import 'package:honeyproxyutility/features/converter/presentation/widgets/parsed_result_card.dart';
import 'package:honeyproxyutility/features/marketplace/presentation/screens/marketplace_screen.dart';
import 'package:honeyproxyutility/features/marketplace/presentation/screens/provider_detail_screen.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/connect_button.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/server_selector_chip.dart';
import 'package:honeyproxyutility/features/connection/presentation/screens/home_screen.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/settings_screen.dart';
import 'package:honeyproxyutility/features/settings/presentation/widgets/yunicode_credit.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/routing_settings_screen.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/dns_settings_screen.dart';
import 'package:honeyproxyutility/features/subscriptions/presentation/screens/subscriptions_screen.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/speed_stats_bar.dart';
import '../support/design_preview.dart' as preview;

void main() {
  testWidgets('export real design widgets when DESIGN_SCREENSHOT_DIR is set', (
    tester,
  ) async {
    final screenshotDir = Platform.environment['DESIGN_SCREENSHOT_DIR'];
    if (screenshotDir == null || screenshotDir.isEmpty) return;
    final previousDisableShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = previousDisableShadows);
    try {
      await tester.runAsync(_loadFonts);
      final boundaryKey = GlobalKey();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        preview.designPreviewApp(showControls: false, repaintKey: boundaryKey),
      );
      await tester.pumpAndSettle();
      final initialProviders = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      await initialProviders
          .read(settingsProvider.notifier)
          .setTheme(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'dark-mobile-disconnected.png',
      );

      await tester.tap(find.byType(ConnectButton));
      await tester.pumpAndSettle();
      _expectPreviewConnection(tester, connected: true, label: 'Отключить');
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'dark-mobile-connected.png',
      );

      final providers = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      await providers.read(settingsProvider.notifier).setTheme(ThemeMode.light);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'light-mobile-connected.png',
      );

      await providers.read(settingsProvider.notifier).setTheme(ThemeMode.dark);
      tester.view.physicalSize = const Size(1100, 800);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'dark-desktop-connected.png',
      );
      await providers.read(settingsProvider.notifier).setTheme(ThemeMode.light);
      await tester.pumpAndSettle();
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'light-desktop-connected.png',
      );

      GoRouter.of(tester.element(find.byType(HomeScreen))).go('/settings');
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'light-desktop-settings.png',
      );
      await providers.read(settingsProvider.notifier).setTheme(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'dark-desktop-settings.png',
      );

      // Capture the signature without an infinite sheen ticker during export.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await providers.read(settingsProvider.notifier).setTheme(ThemeMode.light);
      await tester.pumpAndSettle();
      final settingsScroll = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byType(YuNiCodeCredit),
        400,
        scrollable: settingsScroll,
      );
      await tester.pumpAndSettle();
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'light-desktop-settings-footer.png',
      );
      await tester.tap(find.byKey(const ValueKey('yunicode-website-link')));
      await tester.pumpAndSettle();
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'light-desktop-settings-credit.png',
      );
      await providers.read(settingsProvider.notifier).setTheme(ThemeMode.dark);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(YuNiCodeCredit),
        400,
        scrollable: settingsScroll,
      );
      await tester.pumpAndSettle();
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'dark-mobile-settings-credit.png',
      );
      tester.view.physicalSize = const Size(1100, 800);
      await tester.pumpAndSettle();

      final router = GoRouter.of(tester.element(find.byType(SettingsScreen)));
      router.go('/');
      await providers.read(settingsProvider.notifier).setTheme(ThemeMode.light);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ServerSelectorChip));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('all-servers-chooser')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'light-desktop-server-chooser.png',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(390, 844);
      await providers.read(settingsProvider.notifier).setTheme(ThemeMode.dark);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ServerSelectorChip));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('all-servers-chooser')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'dark-mobile-server-chooser.png',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1100, 800);
      await providers.read(settingsProvider.notifier).setTheme(ThemeMode.light);
      router.go('/converter');
      await tester.pumpAndSettle();
      expect(find.byType(ParsedResultCard), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'light-desktop-import.png',
      );
      router.go('/marketplace');
      await tester.pumpAndSettle();
      expect(find.byType(MarketplaceScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'light-desktop-catalog.png',
      );
      router.push('/marketplace/honeyvpn');
      await tester.pumpAndSettle();
      expect(find.byType(ProviderDetailScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _export(
        tester,
        boundaryKey,
        screenshotDir,
        'light-desktop-provider.png',
      );
    } finally {
      // Flutter checks painting invariants before running registered teardown.
      debugDisableShadows = previousDisableShadows;
    }
  });

  testWidgets('preview Import saves locally and HTTP returns only a fake feed', (
    tester,
  ) async {
    await _pumpInteractivePreview(tester);
    final home = tester.element(find.byType(HomeScreen));
    final container = ProviderScope.containerOf(home);
    GoRouter.of(home).go('/converter');
    await tester.pumpAndSettle();
    expect(find.byType(ConverterScreen), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      preview.designPreviewProxyLink.replaceFirst(
        '#Demo%20Amsterdam',
        '#Manual%20Review',
      ),
    );
    await tester.tap(find.byKey(const ValueKey('import-preview-action')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(ParsedResultCard),
        matching: find.byKey(const ValueKey('import-add-action')),
      ),
    );
    await tester.pumpAndSettle();
    final imported = container.read(serversNotifierProvider).requireValue.last;
    expect(imported.name, 'Manual Review');
    expect(imported.host, 'import.example.invalid');
    expect(imported.subscriptionId, isEmpty);
    expect(container.read(serversNotifierProvider).requireValue, hasLength(4));
    // The production toast owns a three-second timer; let it dismiss while its
    // overlay is mounted rather than carrying it into the next test.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://must-not-fetch.example.test/private-token',
    );
    await tester.tap(find.byKey(const ValueKey('import-preview-action')));
    await tester.pumpAndSettle();
    expect(find.text('Demo Amsterdam'), findsOneWidget);
    expect(find.byType(ParsedResultCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unsupported profile options are explained for direct and downloaded imports',
    (tester) async {
      final adapter = _DelayedHttpAdapter();
      await _pumpInteractivePreview(tester, converterAdapter: adapter);
      GoRouter.of(tester.element(find.byType(HomeScreen))).go('/converter');
      await tester.pumpAndSettle();
      const unsupported =
          'hy2://fake@192.0.2.10:443?pinSHA256=SECRET-FINGERPRINT';
      await tester.enterText(find.byType(TextField), unsupported);
      await tester.tap(find.byKey(const ValueKey('import-preview-action')));
      await tester.pumpAndSettle();
      const explanation =
          'Профиль содержит параметры, которые эта версия не поддерживает.';
      expect(find.text(explanation), findsOneWidget);
      expect(find.byType(ParsedResultCard), findsNothing);
      await tester.enterText(
        find.byType(TextField),
        'https://must-not-fetch.example.test/feed',
      );
      await tester.tap(find.byKey(const ValueKey('import-preview-action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      adapter.responses.single.complete(
        ResponseBody.fromString(unsupported, 200),
      );
      await tester.pumpAndSettle();
      expect(find.text(explanation), findsOneWidget);
      expect(find.byType(ParsedResultCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preview Catalog details and external actions remain synthetic', (
    tester,
  ) async {
    await _pumpInteractivePreview(tester);
    GoRouter.of(tester.element(find.byType(HomeScreen))).go('/marketplace');
    await tester.pumpAndSettle();
    expect(find.byType(MarketplaceScreen), findsOneWidget);
    await tester.tap(find.text('HoneyVPN · Демо'));
    await tester.pumpAndSettle();
    expect(find.byType(ProviderDetailScreen), findsOneWidget);
    await tester.tap(find.text('Открыть сайт'));
    await tester.pumpAndSettle();
    expect(find.text('Демо: внешние ссылки не открываются.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final addFree = find.byKey(const ValueKey('add-built-in-free-server'));
    expect(tester.widget<TextButton>(addFree).onPressed, isNull);
    expect(find.text('Сервер добавлен'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProviderDetailScreen)),
    );
    await container.read(serversNotifierProvider.notifier).delete(1);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить сервер'));
    await tester.pumpAndSettle();
    expect(find.byType(ProviderDetailScreen), findsOneWidget);
    expect(find.byType(ConverterScreen), findsNothing);
    expect(find.text('Сервер добавлен'), findsOneWidget);
    expect(container.read(serversNotifierProvider).requireValue, hasLength(3));
    expect(tester.widget<TextButton>(addFree).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new Import input cannot be replaced by a delayed old response', (
    tester,
  ) async {
    final adapter = _DelayedHttpAdapter();
    await _pumpInteractivePreview(tester, converterAdapter: adapter);
    GoRouter.of(tester.element(find.byType(HomeScreen))).go('/converter');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://must-not-fetch.example.test/old-feed',
    );
    await tester.tap(find.byKey(const ValueKey('import-preview-action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.responses, hasLength(1));
    await tester.enterText(
      find.byType(TextField),
      preview.designPreviewProxyLink.replaceFirst(
        '#Demo%20Amsterdam',
        '#New%20manual',
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('import-preview-action')));
    await tester.pumpAndSettle();
    expect(find.text('New manual'), findsOneWidget);
    expect(adapter.cancellations, 1);
    adapter.complete(
      preview.designPreviewProxyLink.replaceFirst(
        '#Demo%20Amsterdam',
        '#Old%20HTTP',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New manual'), findsOneWidget);
    expect(find.text('Old HTTP'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'leaving Import cancels a pending request without disposed state',
    (tester) async {
      final adapter = _DelayedHttpAdapter();
      await _pumpInteractivePreview(tester, converterAdapter: adapter);
      final router = GoRouter.of(tester.element(find.byType(HomeScreen)));
      router.go('/converter');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://must-not-fetch.example.test/slow-feed',
      );
      await tester.tap(find.byKey(const ValueKey('import-preview-action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.responses, hasLength(1));
      router.go('/');
      await tester.pumpAndSettle();
      expect(find.byType(ConverterScreen), findsNothing);
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.cancellations, 1);
      adapter.complete(preview.designPreviewProxyLink);
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(ConverterScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview Settings uses real theme, locale and port controls with memory-only writes',
    (tester) async {
      await _pumpInteractivePreview(tester);
      final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
      await tester.tap(
        find.descendant(of: sidebar, matching: find.text('Настройки')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsScreen)),
      );

      await tester.tap(find.byIcon(Icons.dark_mode_outlined));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      await tester.tap(find.text('EN'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).requireValue.locale, 'en');
      expect(find.text(const S('en').appearanceSection), findsOneWidget);

      final scrollable = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Proxy Ports'),
        260,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxy Ports'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '10808');
      await tester.enterText(find.byType(TextField).at(1), '10809');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).requireValue.socksPort, 10808);
      expect(container.read(settingsProvider).requireValue.httpPort, 10809);
      expect(find.text('SOCKS 10808  ·  HTTP 10809'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview routing and DNS details use real screens without repositories',
    (tester) async {
      await _pumpInteractivePreview(tester);
      final context = tester.element(find.byType(HomeScreen));
      final container = ProviderScope.containerOf(context);
      final router = GoRouter.of(context);
      router.go('/settings/routing');
      await tester.pumpAndSettle();
      expect(find.byType(RoutingSettingsScreen), findsOneWidget);
      await tester.tap(find.text(const S('ru').geoRoutingCombined));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).requireValue.geoRoutingMode,
        GeoRoutingMode.combined,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Весь трафик'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).requireValue.routingMode,
        RoutingMode.global,
      );
      router.go('/settings/dns');
      await tester.pumpAndSettle();
      expect(find.byType(DnsSettingsScreen), findsOneWidget);
      await tester.tap(find.text('AdGuard'));
      await tester.pumpAndSettle();
      expect(
        container.read(settingsProvider).requireValue.dnsPreset,
        DnsPreset.adguard,
      );

      // Exercise the remaining public setters so future preference controls also
      // remain inside the preview boundary, without platform storage calls.
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setConnectionMode(ConnectionMode.tunnel);
      await notifier.setFragmentation(true);
      await notifier.setMultiplexer(true);
      await notifier.setIpType(IpType.ipv6);
      await notifier.setAllowLan(false);
      await notifier.setTunStack(TunStack.gvisor);
      await notifier.setFakeip(false);
      await notifier.setLogLevel(LogLevel.debug);
      await notifier.setSocksPort(12080);
      await notifier.setHttpPort(12081);
      final settings = container.read(settingsProvider).requireValue;
      expect(settings.fragmentationEnabled, isTrue);
      expect(settings.multiplexerEnabled, isTrue);
      expect(settings.preferredIpType, IpType.ipv6);
      expect(settings.logLevel, LogLevel.debug);
      expect(settings.socksPort, 12080);
      expect(settings.httpPort, 12081);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview subscription navigation and add use only synthetic local nodes',
    (tester) async {
      await _pumpInteractivePreview(tester);
      await tester.tap(find.byTooltip('Подписки'));
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionsScreen), findsOneWidget);
      expect(
        find.text('Демо: подписки временные, ссылки не загружаются.'),
        findsOneWidget,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SubscriptionsScreen)),
      );
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Review demo');
      await tester.enterText(
        find.byType(TextField).at(1),
        'https://not-fetch.example.test/private-token',
      );
      await tester.tap(find.text(const S('ru').addButton));
      await tester.pumpAndSettle();
      expect(find.text('Review demo'), findsOneWidget);
      final added = container
          .read(subscriptionsProvider)
          .requireValue
          .subs
          .last;
      expect(Uri.parse(added.url).host, 'demo.example.invalid');
      expect(added.serverCount, 1);
      expect(
        container
            .read(serversNotifierProvider)
            .requireValue
            .where((s) => s.subscriptionId == added.url),
        hasLength(1),
      );
      await container
          .read(subscriptionsProvider.notifier)
          .setInterval(added.id, 6);
      final singleRefresh = container
          .read(subscriptionsProvider.notifier)
          .refresh(added.id);
      await tester.pump();
      await tester.pump(preview.designPreviewRefreshDuration);
      await singleRefresh;
      final refresh = container
          .read(subscriptionsProvider.notifier)
          .refreshAll();
      await tester.pump();
      await tester.pump(preview.designPreviewRefreshDuration);
      await refresh;
      await tester.pumpAndSettle();
      expect(
        container
            .read(subscriptionsProvider)
            .requireValue
            .subs
            .last
            .updateIntervalHours,
        6,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local preview renders full shell and controls without platform services',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = const Size(1100, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        });
        // Reproduce a web view gaining keyboard focus before the first layout.
        tester.binding.attachRootWidget(
          tester.binding.wrapWithDefaultView(preview.designPreviewApp()),
        );
        tester.binding.handleViewFocusChanged(
          ui.ViewFocusEvent(
            viewId: tester.view.viewId,
            state: ui.ViewFocusState.focused,
            direction: ui.ViewFocusDirection.forward,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Предпросмотр'), findsOneWidget);
        _expectPreviewConnection(tester, connected: false, label: 'Подключить');
        expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
        expect(find.byType(ConnectButton), findsOneWidget);
        for (final label in ['Сменить тему', 'RU', 'Соединение']) {
          final actionable = find.semantics
              .byLabel(RegExp(label))
              .evaluate()
              .where(
                (node) =>
                    node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
              )
              .toList();
          expect(
            actionable,
            hasLength(1),
            reason: '$label must remain actionable above the router',
          );
          expect(actionable.single.getSemanticsData().label, label);
        }

        await tester.tap(find.byType(ConnectButton));
        await tester.pumpAndSettle();
        _expectPreviewConnection(tester, connected: true, label: 'Отключить');
        expect(
          find.semantics
              .byLabel(RegExp('Отключить'))
              .evaluate()
              .any(
                (node) =>
                    node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
              ),
          isTrue,
        );
        expect(find.byType(SpeedStatsBar), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byIcon(Icons.dark_mode_outlined));
        await tester.pumpAndSettle();
        expect(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
          ThemeMode.dark,
        );
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('RU'));
        await tester.pumpAndSettle();
        expect(find.text('Preview'), findsOneWidget);
        _expectPreviewConnection(tester, connected: true, label: 'Disconnect');
        expect(find.text('Connection'), findsAtLeastNWidgets(1));
        expect(tester.takeException(), isNull);

        tester.view.physicalSize = const Size(393, 852);
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(find.byKey(const ValueKey('desktop-sidebar')), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}

void _expectPreviewConnection(
  WidgetTester tester, {
  required bool connected,
  required String label,
}) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HomeScreen)),
  );
  expect(container.read(connectionNotifierProvider).isConnected, connected);
  expect(
    find.descendant(of: find.byType(ConnectButton), matching: find.text(label)),
    findsOneWidget,
  );
}

Future<void> _pumpInteractivePreview(
  WidgetTester tester, {
  HttpClientAdapter? converterAdapter,
}) async {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  await tester.pumpWidget(
    preview.designPreviewApp(
      showControls: false,
      converterAdapter: converterAdapter,
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _DelayedHttpAdapter implements HttpClientAdapter {
  final responses = <Completer<ResponseBody>>[];
  var cancellations = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final response = Completer<ResponseBody>();
    responses.add(response);
    if (cancelFuture != null) {
      unawaited(
        cancelFuture.then<void>((_) {
          cancellations++;
        }),
      );
    }
    return response.future;
  }

  void complete(String text) => responses.single.complete(
    ResponseBody.fromString(
      text,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
      },
    ),
  );

  @override
  void close({bool force = false}) {}
}

Future<void> _loadFonts() async {
  final brand = FontLoader('YuNiCodeBrand')
    ..addFont(rootBundle.load('assets/fonts/YuNiCode/YuNiCode-800.ttf'));
  await brand.load();
  final inter = FontLoader('Inter');
  for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter/Inter-$weight.ttf'));
  }
  await inter.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
  final cupertino = FontLoader('packages/cupertino_icons/CupertinoIcons')
    ..addFont(
      rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
    );
  await cupertino.load();
}

Future<void> _export(
  WidgetTester tester,
  GlobalKey key,
  String directory,
  String name,
) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      final image = element.widget as Image;
      if (image.image is AssetImage) {
        await precacheImage(image.image, element);
      }
    }
  });
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('PNG export failed for $name');
      await Directory(directory).create(recursive: true);
      await File('$directory/$name').writeAsBytes(png.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
