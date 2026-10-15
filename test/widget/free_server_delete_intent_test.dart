import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/servers/presentation/screens/servers_screen.dart';
import 'package:honeyproxyutility/features/servers/presentation/widgets/server_list_tile.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscription_policy.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';

const _paidUrl = 'https://paid.example.test/feed';

ServerProfileModel _profile(int id, String source) => ServerProfileModel(
  id: id,
  protocol: 'vless',
  name: 'Server $id',
  host: 'node-$id.example.test',
  port: 443,
  configJson: jsonEncode({
    'rawLink': 'vless://account-$id@node-$id.example.test:443?security=tls',
  }),
  subscriptionId: source,
  addedAt: DateTime(2026),
);

void main() {
  for (final group in [false, true]) {
    testWidgets(
      'captured ${group ? 'free group' : 'free profile'} deletion survives a rotated ID',
      (tester) async {
        final container = await _render(tester);
        final servers = container.read(serversNotifierProvider.notifier);
        final paidBefore = container
            .read(serversNotifierProvider)
            .requireValue
            .singleWhere((server) => server.subscriptionId == _paidUrl)
            .toJson();
        if (group) {
          final header = find
              .ancestor(
                of: find.text('sub.honeyvpn.ru'),
                matching: find.byType(Row),
              )
              .first;
          await tester.tap(
            find.descendant(
              of: header,
              matching: find.byIcon(Icons.delete_sweep_outlined),
            ),
          );
        } else {
          final freeRow = tester.widget<ServerListTile>(
            find.byWidgetPredicate(
              (widget) => widget is ServerListTile && widget.server.id == 1,
            ),
          );
          freeRow.onDelete();
        }
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);

        // A subscription response replaces the node while its delete dialog is
        // still open. Confirming must remove the free slot, not only old ID 1.
        await servers.replaceSubscription(builtInSubscriptionUrl, [
          const LinkDispatcher().dispatch(
            'vless://new@new.example.test:443?security=tls#New',
          ),
        ]);
        expect(
          container
              .read(serversNotifierProvider)
              .requireValue
              .singleWhere(
                (server) => server.subscriptionId == builtInSubscriptionUrl,
              )
              .id,
          isNot(1),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(FilledButton, 'Delete'),
          ),
        );
        await tester.pumpAndSettle();
        final snapshot = await servers.freeServerSnapshot();
        expect(snapshot.removed, isTrue);
        expect(snapshot.present, isFalse);
        expect(
          container.read(serversNotifierProvider).requireValue.single.toJson(),
          paidBefore,
        );
        expect(
          (await SharedPreferences.getInstance()).getBool(
            'honeyvpn_free_server_removed_v1',
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<ProviderContainer> _render(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'honeyvpn_servers': ServerProfileModel.listToJson([
      _profile(1, builtInSubscriptionUrl),
      _profile(2, _paidUrl),
    ]),
    'honeyvpn_free_server_removed_v1': false,
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionNotifierProvider.overrideWith(_IdleConnection.new),
        stringsProvider.overrideWithValue(const S('en')),
        subscriptionsProvider.overrideWith(_NoNetworkSubscriptions.new),
      ],
      child: MaterialApp(theme: honeyThemeLight, home: const ServersScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(ServersScreen)));
}

class _NoNetworkSubscriptions extends SubscriptionsNotifier {
  @override
  Future<SubscriptionsState> build() async => const SubscriptionsState();
}

class _IdleConnection extends ConnectionNotifier {
  @override
  NexConnectionState build() => NexConnectionState.initial();
}
