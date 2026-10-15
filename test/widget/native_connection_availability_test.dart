import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/connection/presentation/screens/home_screen.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/connect_button.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/server_selector_chip.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/speed_stats_bar.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import '../support/design_preview.dart' as preview;

void main() {
  for (final locale in ['ru', 'en']) {
    testWidgets('unavailable rates differ from measured zero in $locale', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        Future<void> render(VpnStats stats) => tester.pumpWidget(
          ProviderScope(
            overrides: [stringsProvider.overrideWithValue(S(locale))],
            child: MaterialApp(
              theme: honeyThemeLight,
              home: Scaffold(body: SpeedStatsBar(stats: stats)),
            ),
          ),
        );
        await render(VpnStats.zero);
        final download = locale == 'ru'
            ? 'Скорость получения'
            : 'Download speed';
        final unavailable = S(locale).statsUnavailable;
        expect(find.text('—'), findsNWidgets(2));
        expect(
          tester
              .getSemantics(find.bySemanticsLabel(download))
              .getSemanticsData()
              .value,
          unavailable,
        );
        expect(find.byTooltip('$download: $unavailable'), findsOneWidget);
        await render(
          const VpnStats(ratesAvailable: true, trafficAvailable: true),
        );
        final zero = locale == 'ru' ? '0 Б/с' : '0 B/s';
        expect(find.text(zero), findsNWidgets(2));
        expect(find.text('—'), findsNothing);
        expect(
          tester
              .getSemantics(find.bySemanticsLabel(download))
              .getSemanticsData()
              .value,
          zero,
        );
        await render(
          const VpnStats(
            trafficAvailable: true,
            ratesAvailable: false,
            downloadSpeed: 1024,
          ),
        );
        expect(find.text('—'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  testWidgets('native unknown profile never borrows the saved server caption', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        preview.designPreviewScope(
          child: ProviderScope(
            overrides: [
              connectionNotifierProvider.overrideWith(_NativeConnection.new),
              stringsProvider.overrideWithValue(const S('en')),
            ],
            child: MaterialApp(
              theme: honeyThemeForWidth(honeyThemeLight, 800),
              home: const HomeScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      final notifier =
          container.read(connectionNotifierProvider.notifier)
              as _NativeConnection;
      final selector = find.byType(ServerSelectorChip);
      final originalBounds = tester.getRect(
        find.byKey(const ValueKey('primary-connect-control')),
      );
      for (final status in [
        ConnectionStatus.connected,
        ConnectionStatus.disconnecting,
        ConnectionStatus.error,
      ]) {
        notifier.show(status);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.descendant(
            of: selector,
            matching: find.text(const S('en').activeServerUnknown),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: selector, matching: find.text('Нидерланды')),
          findsNothing,
        );
        final data = tester.getSemantics(selector).getSemanticsData();
        expect(data.label, const S('en').activeServerUnknown);
        expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
        expect(
          tester.getRect(find.byKey(const ValueKey('primary-connect-control'))),
          originalBounds,
        );
      }
      // Unknown native error still permits retrying the chosen target after the
      // notifier has confirmed cleanup; honest caption must not disable it.
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: find.byType(ConnectButton),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      final active = ServerProfileModel(
        id: 99,
        protocol: 'vless',
        name: 'Actual active profile',
        host: 'example.invalid',
        port: 443,
        configJson: '{}',
        subscriptionId: '',
        addedAt: DateTime(2026),
      );
      notifier.show(ConnectionStatus.connected, active: active);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: selector, matching: find.text(active.name)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: selector, matching: find.text('Нидерланды')),
        findsNothing,
      );
      notifier.show(ConnectionStatus.disconnected);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: selector, matching: find.text('Нидерланды')),
        findsOneWidget,
      );
      notifier.showLocalPreparing();
      await tester.pump();
      expect(
        find.descendant(of: selector, matching: find.text('Нидерланды')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}

class _NativeConnection extends ConnectionNotifier {
  @override
  NexConnectionState build() => const NexConnectionState(
    status: ConnectionStatus.connected,
    usesNativeSessionIdentity: true,
  );
  void show(ConnectionStatus status, {ServerProfileModel? active}) =>
      state = NexConnectionState(
        status: status,
        activeServer: active,
        usesNativeSessionIdentity: true,
      );
  void showLocalPreparing() =>
      state = const NexConnectionState(status: ConnectionStatus.preparing);
}
