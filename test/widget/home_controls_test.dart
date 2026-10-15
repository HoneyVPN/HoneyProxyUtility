import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/data/vpn_disclosure_provider.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/connection/presentation/screens/home_screen.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/server_selector_chip.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/speed_stats_bar.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/servers/presentation/widgets/server_list_tile.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/models/subscription_model.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';
import 'package:honeyproxyutility/features/update/update_provider.dart';

const _free = 'https://example.invalid/free';
const _plus = 'https://example.invalid/plus';
ServerProfileModel _profile(int id, String name, String subscription) =>
    ServerProfileModel(
      id: id,
      name: name,
      subscriptionId: subscription,
      host: 'example.invalid',
      port: 443,
      protocol: 'vless',
      configJson: '{}',
      addedAt: DateTime(2026),
      isSelected: id == 1,
    );
final _profiles = [
  _profile(1, 'NL Free Netherlands', _free),
  _profile(2, 'DE Plus Germany', _plus),
  _profile(3, 'FR Manual France', ''),
];

void main() {
  testWidgets('a removed chooser entry cannot switch an active VPN', (
    tester,
  ) async {
    final container = await _render(tester, _profiles);
    final connection =
        container.read(connectionNotifierProvider.notifier) as _Connection;
    connection.show(ConnectionStatus.connected);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ServerSelectorChip));
    await tester.pumpAndSettle();
    final chooser = find.byKey(const ValueKey('all-servers-chooser'));
    final choice = find.byKey(const ValueKey('choose-server-2'));
    await tester.scrollUntilVisible(
      choice,
      100,
      scrollable: find.descendant(
        of: find.descendant(of: chooser, matching: find.byType(ListView)),
        matching: find.byType(Scrollable),
      ),
    );
    (container.read(serversNotifierProvider.notifier) as _Servers)
            .deleteBeforeSelection =
        2;
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(connection.connectCalls, 0);
    expect(container.read(connectionNotifierProvider).activeServer?.id, 1);
    expect(container.read(selectedServerProvider)?.id, 1);
    expect(find.text(const S('en').favoriteServerChanged), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final (size, platform, diameter, textScale) in [
    (const Size(390, 844), TargetPlatform.android, 160.0, 1.0),
    (const Size(1100, 800), TargetPlatform.android, 160.0, 1.0),
    (const Size(520, 900), TargetPlatform.windows, 224.0, 1.0),
    (const Size(520, 420), TargetPlatform.windows, 160.0, 1.0),
    (const Size(520, 900), TargetPlatform.macOS, 224.0, 1.0),
    (const Size(320, 420), TargetPlatform.android, 184.0, 2.0),
    (const Size(320, 420), TargetPlatform.windows, 144.0, 2.0),
  ]) {
    testWidgets(
      '${platform.name} connection target and live metrics stay fixed across states and server scroll at $size scale $textScale',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final previousPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = platform;
        try {
          final container = await _render(tester, [
            ..._profiles,
            for (var i = 4; i < 20; i++) _profile(i, 'Extra server $i', _plus),
          ], textScale: textScale);
          final target = find.byKey(const ValueKey('primary-connect-control'));
          final original = tester.getRect(target);
          expect(original.size, Size(diameter, diameter));
          expect(original.center.dx, size.width / 2);
          if (diameter == 224) {
            expect(
              original.top - tester.getRect(find.byType(AppBar)).bottom,
              greaterThanOrEqualTo(36),
            );
          }
          final connection =
              container.read(connectionNotifierProvider.notifier)
                  as _Connection;
          for (final status in ConnectionStatus.values) {
            connection.show(status);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.getRect(target), original, reason: status.name);
            expect(find.text(const S('en').statusDisconnected), findsNothing);
            expect(
              find.byType(SpeedStatsBar),
              status == ConnectionStatus.connected
                  ? findsOneWidget
                  : findsNothing,
            );
          }
          connection.show(ConnectionStatus.disconnected);
          await tester.pumpAndSettle();
          container
              .read(latencyTestProgressProvider.notifier)
              .update(
                const LatencyTestProgress(
                  isRunning: true,
                  completed: 2,
                  total: 19,
                  activeIds: {3},
                ),
              );
          await tester.pump();
          expect(tester.getRect(target), original);
          container
              .read(latencyTestProgressProvider.notifier)
              .update(const LatencyTestProgress());
          await tester.pumpAndSettle();
          connection.show(
            ConnectionStatus.connected,
            stats: const VpnStats(
              downloadSpeed: 12 * 1024 * 1024,
              uploadSpeed: 1024 * 1024,
              sessionDuration: Duration(minutes: 1),
            ),
          );
          await tester.pumpAndSettle();
          final metrics = [
            find.byTooltip('Download speed'),
            find.byTooltip('Upload speed'),
            find.byTooltip('Connection duration'),
          ];
          final metricCenters = metrics
              .map((metric) => tester.getRect(metric).center.dx)
              .toList();
          final metricsAnchor = tester
              .getRect(find.byType(SpeedStatsBar))
              .topLeft;
          expect(
            find.descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(SpeedStatsBar),
            ),
            findsNothing,
          );
          connection.show(
            ConnectionStatus.connected,
            stats: const VpnStats(
              downloadSpeed: 23.5 * 1024 * 1024,
              uploadSpeed: 8 * 1024,
              sessionDuration: Duration(hours: 1, minutes: 2, seconds: 3),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('23.5 MB/s'), findsOneWidget);
          expect(find.text('8 KB/s'), findsOneWidget);
          expect(find.text('01:02:03'), findsOneWidget);
          expect(
            metrics.map((metric) => tester.getRect(metric).center.dx).toList(),
            metricCenters,
          );
          expect(
            tester.getRect(find.byType(SpeedStatsBar)).topLeft,
            metricsAnchor,
          );
          final metricBounds = metrics.map(tester.getRect).toList();
          final scrolling = tester.state<ScrollableState>(
            find.descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            ),
          );
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -300),
          );
          await tester.pumpAndSettle();
          expect(scrolling.position.pixels, greaterThan(0));
          expect(tester.getRect(target), original);
          expect(metrics.map(tester.getRect).toList(), metricBounds);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          debugDefaultTargetPlatformOverride = previousPlatform;
        }
      },
    );
  }

  testWidgets(
    'server row opens all subscriptions with flags and direct latency check',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        final container = await _render(tester, _profiles);
        final row = find.byType(ServerSelectorChip);
        final data = tester.getSemantics(row).getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
        final material = tester.widget<Material>(
          find.byKey(const ValueKey('selected-server-control')),
        );
        expect(material.color, Colors.transparent);
        expect(data.label, 'Free Netherlands');
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(ServerListTile), findsNWidgets(3));
        await tester.tap(find.byTooltip(const S('en').pingAllTooltip));
        await tester.pumpAndSettle();
        expect(
          (container.read(serversNotifierProvider.notifier) as _Servers)
              .latencyChecks,
          1,
        );
        expect(container.read(selectedServerProvider)?.id, 1);
        await tester.tap(row);
        await tester.pumpAndSettle();
        final chooser = find.byKey(const ValueKey('all-servers-chooser'));
        for (final id in [1, 2, 3]) {
          expect(find.byKey(ValueKey('choose-server-$id')), findsOneWidget);
        }
        expect(
          find.descendant(
            of: chooser,
            matching: find.text('Free subscription'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: chooser,
            matching: find.text('Plus subscription'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: chooser,
            matching: find.text(const S('en').manualGroup),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: chooser, matching: find.byType(TextField)),
          findsNothing,
        );
        await tester.tap(
          find.descendant(
            of: chooser,
            matching: find.byKey(const ValueKey('check-server-latency')),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          (container.read(serversNotifierProvider.notifier) as _Servers)
              .latencyChecks,
          2,
        );
        expect(find.byKey(const ValueKey('choose-server-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('choose-server-3')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(chooser, findsNothing);
        await tester.tap(row);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('choose-server-3')));
        await tester.pumpAndSettle();
        expect(container.read(selectedServerProvider)?.id, 3);
        expect(
          (container.read(connectionNotifierProvider.notifier) as _Connection)
              .connectCalls,
          0,
        );
        expect(chooser, findsNothing);
        expect(find.text('Manual France'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'latency check can be stopped from the chooser without changing the connection',
    (tester) async {
      try {
        final container = await _render(tester, _profiles);
        final connection =
            container.read(connectionNotifierProvider.notifier) as _Connection;
        connection.show(ConnectionStatus.connected);
        await tester.pumpAndSettle();
        container
            .read(latencyTestProgressProvider.notifier)
            .update(
              const LatencyTestProgress(
                isRunning: true,
                completed: 1,
                total: 3,
                activeIds: {2, 3},
              ),
            );
        await tester.pump();
        await tester.tap(find.byType(ServerSelectorChip));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final chooser = find.byKey(const ValueKey('all-servers-chooser'));
        final latencyAction = find.descendant(
          of: chooser,
          matching: find.byKey(const ValueKey('check-server-latency')),
        );
        expect(
          tester.getSemantics(latencyAction).getSemanticsData().value,
          'Checking: 1 of 3',
        );
        expect(find.text('Checking: 1 of 3'), findsNothing);
        await tester.tap(
          find.descendant(
            of: chooser,
            matching: find.byKey(const ValueKey('check-server-latency')),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          (container.read(serversNotifierProvider.notifier) as _Servers)
              .latencyCancellations,
          1,
        );
        expect(container.read(connectionNotifierProvider).isConnected, isTrue);
        expect(container.read(selectedServerProvider)?.id, 1);
        expect(chooser, findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'chooser supports Enter and prevents changing a server during transition',
    (tester) async {
      try {
        final container = await _render(tester, _profiles);
        final connection =
            container.read(connectionNotifierProvider.notifier) as _Connection;
        connection.show(ConnectionStatus.connecting);
        await tester.pump();
        await tester.tap(find.byType(ServerSelectorChip));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final chooser = find.byKey(const ValueKey('all-servers-chooser'));
        expect(chooser, findsOneWidget);
        final choice = find.byKey(const ValueKey('choose-server-2'));
        await tester.scrollUntilVisible(
          choice,
          100,
          scrollable: find.descendant(
            of: find.descendant(of: chooser, matching: find.byType(ListView)),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pump();
        expect(tester.widget<ListTile>(choice).enabled, isFalse);
        await tester.tap(choice);
        await tester.pump();
        expect(container.read(selectedServerProvider)?.id, 1);
        expect(connection.connectCalls, 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        connection.show(ConnectionStatus.connected);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(ServerSelectorChip));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          choice,
          100,
          scrollable: find.descendant(
            of: find.descendant(of: chooser, matching: find.byType(ListView)),
            matching: find.byType(Scrollable),
          ),
        );
        Focus.of(
          tester.element(
            find.descendant(of: choice, matching: find.text('Plus Germany')),
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(container.read(selectedServerProvider)?.id, 2);
        expect(container.read(connectionNotifierProvider).activeServer?.id, 2);
        expect(connection.connectCalls, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );
}

Future<ProviderContainer> _render(
  WidgetTester tester,
  List<ServerProfileModel> profiles, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionNotifierProvider.overrideWith(_Connection.new),
        serversNotifierProvider.overrideWith(() => _Servers(profiles)),
        subscriptionsProvider.overrideWith(_Subscriptions.new),
        settingsProvider.overrideWith(_Settings.new),
        vpnDisclosureProvider.overrideWith(_Disclosure.new),
        updateProvider.overrideWithValue(const AsyncData(null)),
        stringsProvider.overrideWithValue(const S('en')),
      ],
      child: MaterialApp(
        theme: honeyThemeLight,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));
}

class _Connection extends ConnectionNotifier {
  var connectCalls = 0;
  @override
  NexConnectionState build() => NexConnectionState.initial();
  void show(ConnectionStatus status, {VpnStats stats = VpnStats.zero}) =>
      state = NexConnectionState(
        status: status,
        activeServer: status == ConnectionStatus.disconnected
            ? null
            : _profiles.first,
        errorMessage: status == ConnectionStatus.error
            ? 'Example failure'
            : null,
        stats: stats,
      );
  @override
  Future<void> connect(ServerProfileModel server) async {
    connectCalls++;
    state = NexConnectionState(
      status: ConnectionStatus.connected,
      activeServer: server,
    );
  }
}

class _Servers extends ServersNotifier {
  final List<ServerProfileModel> initial;
  var latencyChecks = 0;
  var latencyCancellations = 0;
  int? deleteBeforeSelection;
  _Servers(this.initial);
  @override
  Future<List<ServerProfileModel>> build() async => initial;
  @override
  Future<void> testAllLatency() async {
    latencyChecks++;
  }

  @override
  Future<void> cancelLatencyTests() async {
    latencyCancellations++;
    ref
        .read(latencyTestProgressProvider.notifier)
        .update(const LatencyTestProgress());
  }

  @override
  Future<void> selectServer(ServerProfileModel server) async =>
      state = AsyncData([
        for (final profile in state.requireValue)
          profile.copyWith(isSelected: profile.id == server.id),
      ]);

  @override
  Future<bool> selectServerIfCurrent(ServerProfileModel expected) async {
    if (deleteBeforeSelection != null) {
      state = AsyncData([
        for (final profile in state.requireValue)
          if (profile.id != deleteBeforeSelection) profile,
      ]);
      deleteBeforeSelection = null;
    }
    if (!state.requireValue.any(expected.hasSameConnectionIdentity))
      return false;
    await selectServer(expected);
    return true;
  }
}

class _Subscriptions extends SubscriptionsNotifier {
  @override
  Future<SubscriptionsState> build() async => const SubscriptionsState(
    subs: [
      SubscriptionModel(id: 1, url: _free, name: 'Free subscription'),
      SubscriptionModel(id: 2, url: _plus, name: 'Plus subscription'),
    ],
  );
}

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(locale: 'en');
}

class _Disclosure extends VpnDisclosureNotifier {
  @override
  Future<bool> build() async => true;
}
