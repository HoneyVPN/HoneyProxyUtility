import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/data/vpn_disclosure_provider.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/connection/presentation/screens/home_screen.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/servers/presentation/screens/servers_screen.dart';
import 'package:honeyproxyutility/features/servers/presentation/widgets/server_list_tile.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/models/subscription_model.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscription_policy.dart';
import 'package:honeyproxyutility/features/subscriptions/presentation/screens/subscriptions_screen.dart'
    show SubscriptionsScreen;
import 'package:honeyproxyutility/features/update/update_provider.dart';

const _url = 'https://example.invalid/sub';
final _server = ServerProfileModel(
  id: 1,
  protocol: 'vless',
  name: 'Test server',
  host: 'example.invalid',
  port: 443,
  configJson: '{}',
  subscriptionId: _url,
  addedAt: DateTime(2026),
  isSelected: true,
);

ServerProfileModel _freeServer(int id) => ServerProfileModel(
  id: id,
  protocol: 'vless',
  name: 'Free server $id',
  host: 'example.invalid',
  port: 443,
  configJson: '{}',
  subscriptionId: builtInSubscriptionUrl,
  addedAt: DateTime(2026),
  isSelected: true,
);

void main() {
  for (final target in [
    'server',
    'group',
    'subscription',
    'servers-list-server',
    'servers-list-group',
  ]) {
    testWidgets(
      'deleting an active $target waits for stop and keeps profiles on failure',
      (tester) async {
        tester.view.physicalSize = const Size(900, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final record = _Record();
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                connectionNotifierProvider.overrideWith(
                  () => _FailingStop(record),
                ),
                serversNotifierProvider.overrideWith(() => _Servers(record)),
                subscriptionsProvider.overrideWith(
                  () => _Subscriptions(record),
                ),
                settingsProvider.overrideWith(_Settings.new),
                stringsProvider.overrideWithValue(const S('en')),
                vpnDisclosureProvider.overrideWith(_Disclosure.new),
                updateProvider.overrideWithValue(const AsyncData(null)),
              ],
              child: MaterialApp(
                theme: honeyThemeLight,
                home: target.startsWith('servers-list')
                    ? const ServersScreen()
                    : target == 'subscription'
                    ? const SubscriptionsScreen()
                    : const HomeScreen(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (target == 'server' || target == 'servers-list-server') {
            await tester.tap(find.byKey(const ValueKey('server-actions-1')));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Delete'));
          } else if (target == 'group') {
            await tester.tap(find.byTooltip('Subscription actions'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Delete'));
          } else if (target == 'servers-list-group') {
            await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
          } else {
            await tester.tap(find.byIcon(Icons.delete_outline));
          }
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
          await tester.pump();
          expect(record.stopCalls, 1);
          expect(record.serverDeletes, 0);
          expect(record.subscriptionDeletes, 0);
          record.stop.complete();
          await tester.pumpAndSettle();
          expect(record.serverDeletes, 0);
          expect(record.subscriptionDeletes, 0);
          expect(find.text(const S('en').vpnStopFailed), findsOneWidget);
          if (target != 'subscription')
            expect(find.byType(ServerListTile), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          if (!record.stop.isCompleted) record.stop.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );
  }

  for (final screen in ['home', 'servers']) {
    for (final stopSucceeds in [false, true]) {
      testWidgets(
        '$screen deleting a refreshed free slot waits for its active replacement and preserves captured source when stop=$stopSucceeds',
        (tester) async {
          final old = _freeServer(1);
          final replacement = _freeServer(2);
          final record = _Record()
            ..visible = [old]
            ..active = old
            ..stopSucceeds = stopSucceeds;
          try {
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  connectionNotifierProvider.overrideWith(
                    () => _FailingStop(record),
                  ),
                  serversNotifierProvider.overrideWith(() => _Servers(record)),
                  subscriptionsProvider.overrideWith(
                    () => _Subscriptions(record),
                  ),
                  settingsProvider.overrideWith(_Settings.new),
                  stringsProvider.overrideWithValue(const S('en')),
                  vpnDisclosureProvider.overrideWith(_Disclosure.new),
                  updateProvider.overrideWithValue(const AsyncData(null)),
                ],
                child: MaterialApp(
                  theme: honeyThemeLight,
                  home: screen == 'servers'
                      ? const ServersScreen()
                      : const HomeScreen(),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('server-actions-1')));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Delete'));
            await tester.pumpAndSettle();
            final container = ProviderScope.containerOf(
              tester.element(
                screen == 'servers'
                    ? find.byType(ServersScreen)
                    : find.byType(HomeScreen),
              ),
            );
            if (screen == 'home') {
              (container.read(serversNotifierProvider.notifier) as _Servers)
                  .replaceVisible(replacement);
              (container.read(connectionNotifierProvider.notifier)
                      as _FailingStop)
                  .showActive(replacement);
            }
            await tester.pump();
            await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
            await tester.pump();
            expect(record.stopCalls, 1);
            expect(record.serverDeletes, 0);
            if (screen == 'servers') {
              // The awaited stop must not switch the captured deletion to a
              // different ID; a rotated free slot still uses its source lease.
              (container.read(serversNotifierProvider.notifier) as _Servers)
                  .replaceVisible(replacement);
              (container.read(connectionNotifierProvider.notifier)
                      as _FailingStop)
                  .showActive(replacement);
              await tester.pump();
            }
            record.stop.complete();
            await tester.pumpAndSettle();
            expect(record.serverDeletes, stopSucceeds ? 1 : 0);
            expect(record.subscriptionDeletes, 0);
            if (stopSucceeds) {
              expect(record.deletedId, old.id);
              expect(record.expectedSubscriptionId, builtInSubscriptionUrl);
            } else {
              expect(find.text(const S('en').vpnStopFailed), findsOneWidget);
              expect(
                find.byKey(const ValueKey('server-actions-2')),
                findsOneWidget,
              );
            }
            expect(tester.takeException(), isNull);
          } finally {
            if (!record.stop.isCompleted) record.stop.complete();
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          }
        },
      );
    }
  }
}

class _Record {
  final stop = Completer<void>();
  var stopCalls = 0;
  var serverDeletes = 0;
  var subscriptionDeletes = 0;
  var stopSucceeds = false;
  List<ServerProfileModel> visible = [_server];
  ServerProfileModel active = _server;
  int? deletedId;
  String? expectedSubscriptionId;
}

class _FailingStop extends ConnectionNotifier {
  final _Record record;
  _FailingStop(this.record);
  @override
  NexConnectionState build() => NexConnectionState(
    status: ConnectionStatus.connected,
    activeServer: record.active,
  );
  void showActive(ServerProfileModel server) =>
      state = state.copyWith(activeServer: server);
  @override
  Future<void> disconnect() async {
    record.stopCalls++;
    state = state.copyWith(status: ConnectionStatus.disconnecting);
    await record.stop.future;
    if (ref.mounted) {
      state = record.stopSucceeds
          ? NexConnectionState.initial()
          : state.copyWith(
              status: ConnectionStatus.error,
              errorMessage: 'Stop remains unconfirmed',
            );
    }
  }
}

class _Servers extends ServersNotifier {
  final _Record record;
  _Servers(this.record);
  @override
  Future<List<ServerProfileModel>> build() async => record.visible;
  void replaceVisible(ServerProfileModel server) => state = AsyncData([server]);
  @override
  Future<void> delete(int id, {String? expectedSubscriptionId}) async {
    record.serverDeletes++;
    record.deletedId = id;
    record.expectedSubscriptionId = expectedSubscriptionId;
    state = const AsyncData([]);
  }
}

class _Subscriptions extends SubscriptionsNotifier {
  final _Record record;
  _Subscriptions(this.record);
  @override
  Future<SubscriptionsState> build() async => const SubscriptionsState(
    subs: [
      SubscriptionModel(
        id: 1,
        url: _url,
        name: 'Test subscription',
        serverCount: 1,
      ),
    ],
  );
  @override
  Future<void> delete(int id) async {
    record.subscriptionDeletes++;
    state = const AsyncData(SubscriptionsState());
  }
}

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(locale: 'en');
}

class _Disclosure extends VpnDisclosureNotifier {
  @override
  Future<bool> build() async => true;
}
