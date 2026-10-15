import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/data/vpn_disclosure_provider.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/connection/presentation/screens/home_screen.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/connect_button.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/server_selector_chip.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/speed_stats_bar.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';
import 'package:honeyproxyutility/features/update/update_provider.dart';

final _server = ServerProfileModel(
  id: 1,
  protocol: 'vless',
  name: 'HoneyVPN · Сервер с длинным названием для проверки адаптивности',
  host: 'example.com',
  port: 443,
  configJson: '{}',
  subscriptionId: 'https://example.com/sub',
  addedAt: DateTime(2026, 1, 1),
  isSelected: true,
);

void main() {
  for (final theme in [honeyThemeLight, honeyThemeDark]) {
    test(
      '${theme.brightness.name} theme keeps body and accent text readable',
      () {
        final cs = theme.colorScheme;
        for (final foreground in [
          cs.onSurface,
          cs.onSurfaceVariant,
          cs.primary,
        ]) {
          expect(_contrast(foreground, cs.surface), greaterThanOrEqualTo(4.5));
        }
        expect(_contrast(cs.tertiary, cs.surface), greaterThanOrEqualTo(4.5));
        expect(_contrast(cs.error, cs.surface), greaterThanOrEqualTo(4.5));
      },
    );
  }

  testWidgets(
    'connect action has a label and suppresses taps during transitions',
    (tester) async {
      var taps = 0;
      Future<void> render(ConnectionStatus status, {bool enabled = true}) =>
          tester.pumpWidget(
            ProviderScope(
              overrides: [stringsProvider.overrideWithValue(const S('ru'))],
              child: MaterialApp(
                theme: honeyThemeLight,
                home: Scaffold(
                  body: ConnectButton(
                    status: status,
                    enabled: enabled,
                    onTap: () => taps++,
                  ),
                ),
              ),
            ),
          );
      await render(ConnectionStatus.disconnected);
      expect(find.text('Подключить'), findsOneWidget);
      final hitTarget = tester.getSize(
        find.byKey(const ValueKey('primary-connect-control')),
      );
      expect(hitTarget.width, greaterThanOrEqualTo(144));
      expect(hitTarget.height, greaterThanOrEqualTo(144));
      await tester.tap(find.byType(ConnectButton));
      expect(taps, 1);
      await render(ConnectionStatus.connecting);
      await tester.tap(find.byType(ConnectButton));
      expect(taps, 1);
      expect(find.text(const S('ru').connecting), findsOneWidget);
      await render(ConnectionStatus.disconnected, enabled: false);
      await tester.tap(find.byType(ConnectButton));
      expect(taps, 1);
    },
  );

  testWidgets(
    'selected server and stats fit narrow width and large Russian text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [stringsProvider.overrideWithValue(const S('ru'))],
          child: MaterialApp(
            theme: honeyThemeDark,
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 480),
                textScaler: TextScaler.linear(2),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        ServerSelectorChip(server: _server, onTap: () {}),
                        const SizedBox(height: 12),
                        const SpeedStatsBar(
                          stats: VpnStats(downloadSpeed: 12 * 1024 * 1024),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('12.0 МБ/с'), findsOneWidget);
      expect(find.byTooltip('Скорость получения'), findsOneWidget);
      expect(find.byTooltip('Скорость отправки'), findsOneWidget);
      expect(find.byTooltip('Время подключения'), findsOneWidget);
    },
  );

  for (final (platform, size) in [
    (TargetPlatform.macOS, const Size(320, 420)),
    (TargetPlatform.windows, const Size(320, 420)),
    (TargetPlatform.macOS, const Size(520, 900)),
    (TargetPlatform.windows, const Size(520, 900)),
  ]) {
    testWidgets(
      '${platform.name} home remains scrollable at $size with large text',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final previousPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = platform;
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                connectionNotifierProvider.overrideWith(_PreviewConnection.new),
                serversNotifierProvider.overrideWith(_PreviewServers.new),
                subscriptionsProvider.overrideWith(_PreviewSubscriptions.new),
                settingsProvider.overrideWith(_PreviewSettings.new),
                vpnDisclosureProvider.overrideWith(_PreviewDisclosure.new),
                updateProvider.overrideWithValue(const AsyncData(null)),
              ],
              child: MaterialApp(
                theme: honeyThemeLight,
                home: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: const TextScaler.linear(2),
                  ),
                  child: const HomeScreen(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(CustomScrollView), findsOneWidget);
          final action = find.byKey(const ValueKey('primary-connect-control'));
          final originalBounds = tester.getRect(action);
          expect(
            originalBounds.width,
            platform == TargetPlatform.windows && size.height < 480
                ? 144
                : size.width >= 400
                ? 248
                : 184,
          );
          if (platform == TargetPlatform.windows) {
            final mode = find.byType(SegmentedButton<ConnectionMode>);
            expect(mode, findsOneWidget);
            await tester.ensureVisible(mode);
            await tester.tap(
              find.text(const S('ru').connectionModeShortLabel('proxy')),
            );
            await tester.pumpAndSettle();
            final container = ProviderScope.containerOf(
              tester.element(find.byType(HomeScreen)),
            );
            expect(
              container.read(settingsProvider).requireValue.connectionMode,
              ConnectionMode.proxy,
            );
            expect(tester.getRect(action), originalBounds);
          } else {
            expect(find.byType(SegmentedButton<ConnectionMode>), findsNothing);
          }
          await tester.scrollUntilVisible(find.text('Серверы'), 160);
          expect(tester.takeException(), isNull);
          expect(find.text('Серверы'), findsOneWidget);
          expect(tester.getRect(action), originalBounds);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          debugDefaultTargetPlatformOverride = previousPlatform;
        }
      },
    );
  }
}

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final brighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (brighter + 0.05) / (darker + 0.05);
}

class _PreviewConnection extends ConnectionNotifier {
  @override
  NexConnectionState build() => NexConnectionState.initial();
}

class _PreviewServers extends ServersNotifier {
  @override
  Future<List<ServerProfileModel>> build() async => [_server];
}

class _PreviewSubscriptions extends SubscriptionsNotifier {
  @override
  Future<SubscriptionsState> build() async => const SubscriptionsState();
}

class _PreviewSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(locale: 'ru');

  @override
  Future<void> setConnectionMode(ConnectionMode mode) async {
    state = AsyncData(state.requireValue.copyWith(connectionMode: mode));
  }
}

class _PreviewDisclosure extends VpnDisclosureNotifier {
  @override
  Future<bool> build() async => true;
}
