import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/presentation/screens/home_screen.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/server_selector_chip.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/servers/presentation/screens/servers_screen.dart';
import 'package:honeyproxyutility/features/servers/presentation/widgets/server_list_tile.dart';

import '../support/design_preview.dart' as preview;

ServerProfileModel profile({String source = 'https://one.example.invalid'}) =>
    ServerProfileModel(
      id: 1,
      protocol: 'vless',
      name: 'NL Netherlands',
      host: 'example.invalid',
      port: 443,
      configJson: '{"source":"$source"}',
      subscriptionId: source,
      addedAt: DateTime(2026),
      isSelected: true,
    );

class _Profiles extends ServersNotifier {
  bool fail = false;
  @override
  Future<List<ServerProfileModel>> build() async => [profile()];

  void replace(ServerProfileModel replacement) =>
      state = AsyncData([replacement]);

  @override
  Future<bool> setFavoriteIfCurrent(
    ServerProfileModel expected,
    bool isFavorite,
  ) {
    if (fail) throw StateError('Synthetic failed write');
    return super.setFavoriteIfCurrent(expected, isFavorite);
  }
}

Widget tileApp(_Profiles profiles, S strings) => ProviderScope(
  overrides: [
    serversNotifierProvider.overrideWith(() => profiles),
    stringsProvider.overrideWithValue(strings),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: Consumer(
        builder: (context, ref, _) {
          final server = ref.watch(serversNotifierProvider).value?.firstOrNull;
          if (server == null) return const SizedBox.shrink();
          return ServerListTile(
            key: ValueKey(server.id),
            server: server,
            isSelected: server.isSelected,
            onTap: () {},
            onDelete: () {},
            onTapDetail: () {},
          );
        },
      ),
    ),
  ),
);

Future<void> openMenu(WidgetTester tester, int id) async {
  await tester.ensureVisible(find.byKey(ValueKey('server-actions-$id')));
  await tester.tap(find.byKey(ValueKey('server-actions-$id')));
  await tester.pumpAndSettle();
}

Future<ProviderContainer> renderMainList(WidgetTester tester, bool home) async {
  tester.view.physicalSize = const Size(390, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    home
        ? preview.designPreviewApp(showControls: false)
        : preview.designPreviewScope(
            child: const MaterialApp(home: ServersScreen()),
          ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(home ? HomeScreen : ServersScreen)),
  );
}

Future<void> openGroupDelete(
  WidgetTester tester,
  Finder header, {
  required bool home,
}) async {
  if (home) {
    await tester.tap(
      find.descendant(of: header, matching: find.byType(PopupMenuButton<bool>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(const S('ru').deleteButton));
  } else {
    await tester.tap(
      find.descendant(
        of: header,
        matching: find.byIcon(Icons.delete_sweep_outlined),
      ),
    );
  }
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in ['ru', 'en']) {
    testWidgets(
      'favorite menu adds and removes without selecting another server $locale',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          SharedPreferences.setMockInitialValues({});
          final profiles = _Profiles();
          final strings = S(locale);
          await tester.pumpWidget(tileApp(profiles, strings));
          await tester.pumpAndSettle();
          await openMenu(tester, 1);
          expect(find.text(strings.addToFavorites), findsOneWidget);
          await tester.tap(find.text(strings.addToFavorites));
          await tester.pumpAndSettle();
          expect(profiles.state.requireValue.single.isFavorite, isTrue);
          expect(profiles.state.requireValue.single.isSelected, isTrue);
          expect(find.byTooltip(strings.favoriteServer), findsOneWidget);
          final favoriteSemantics = find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.value == strings.favoriteServer,
          );
          expect(favoriteSemantics, findsOneWidget);
          expect(
            tester.getSemantics(favoriteSemantics).getSemanticsData().value,
            strings.favoriteServer,
          );
          expect(
            find.bySemanticsLabel(
              RegExp(RegExp.escape(strings.favoriteServer)),
            ),
            findsNothing,
          );
          await openMenu(tester, 1);
          expect(find.text(strings.removeFromFavorites), findsOneWidget);
          await tester.tap(find.text(strings.removeFromFavorites));
          await tester.pumpAndSettle();
          expect(profiles.state.requireValue.single.isFavorite, isFalse);
          expect(profiles.state.requireValue.single.isSelected, isTrue);
          expect(find.byTooltip(strings.favoriteServer), findsNothing);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'an open favorite menu cannot change a replacement with reused ID',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final profiles = _Profiles();
      const strings = S('en');
      await tester.pumpWidget(tileApp(profiles, strings));
      await tester.pumpAndSettle();
      await openMenu(tester, 1);
      profiles.replace(profile(source: 'https://replacement.example.invalid'));
      await tester.pump();
      await tester.tap(find.text(strings.addToFavorites));
      await tester.pumpAndSettle();
      expect(profiles.state.requireValue.single.isFavorite, isFalse);
      expect(find.text(strings.favoriteServerChanged), findsOneWidget);
    },
  );

  testWidgets(
    'failed favorite save shows a retryable error without changing state',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final profiles = _Profiles()..fail = true;
      const strings = S('en');
      await tester.pumpWidget(tileApp(profiles, strings));
      await tester.pumpAndSettle();
      await openMenu(tester, 1);
      await tester.tap(find.text(strings.addToFavorites));
      await tester.pumpAndSettle();
      expect(profiles.state.requireValue.single.isFavorite, isFalse);
      expect(find.text(strings.favoriteUpdateFailed), findsOneWidget);
      profiles.fail = false;
      await openMenu(tester, 1);
      await tester.tap(find.text(strings.addToFavorites));
      await tester.pumpAndSettle();
      expect(profiles.state.requireValue.single.isFavorite, isTrue);
    },
  );

  testWidgets(
    'demo favorites move to the chooser first without duplicates or selection changes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(preview.designPreviewApp(showControls: false));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      final selected = container.read(selectedServerProvider)!.id;
      final all = container.read(serversNotifierProvider).requireValue;
      final favorite = all.last;
      await openMenu(tester, favorite.id);
      await tester.tap(find.text(const S('ru').addToFavorites));
      await tester.pumpAndSettle();
      expect(container.read(selectedServerProvider)!.id, selected);
      expect(
        container.read(serversNotifierProvider).requireValue,
        hasLength(all.length),
      );
      expect(find.text(const S('ru').favoritesTitle), findsOneWidget);
      await tester.tap(find.byType(ServerSelectorChip));
      await tester.pumpAndSettle();
      final dialog = find.byType(Dialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.text(const S('ru').favoritesTitle),
        ),
        findsOneWidget,
      );
      final row = find.descendant(
        of: dialog,
        matching: find.byKey(ValueKey('choose-server-${favorite.id}')),
      );
      expect(row, findsOneWidget);
      for (final server in all.where((server) => server.id != favorite.id)) {
        final other = find.descendant(
          of: dialog,
          matching: find.byKey(ValueKey('choose-server-${server.id}')),
        );
        expect(other, findsOneWidget);
        expect(
          tester.getTopLeft(row).dy,
          lessThan(tester.getTopLeft(other).dy),
        );
      }
      await tester.tap(find.byTooltip(const S('ru').closeButton));
      await tester.pumpAndSettle();
      await openMenu(tester, favorite.id);
      await tester.tap(find.text(const S('ru').removeFromFavorites));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ServerSelectorChip));
      await tester.pumpAndSettle();
      expect(find.text(const S('ru').favoritesTitle), findsNothing);
      expect(container.read(selectedServerProvider)!.id, selected);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final home in [true, false]) {
    testWidgets(
      '${home ? 'home' : 'servers'} favorites group moves rows without duplication or source changes',
      (tester) async {
        final container = await renderMainList(tester, home);
        const strings = S('ru');
        final original = container.read(serversNotifierProvider).requireValue;
        final selected = container.read(selectedServerProvider)!.id;
        final sources = {
          for (final server in original) server.id: server.subscriptionId,
        };
        final paid = original
            .where(
              (server) => server.subscriptionId == original.last.subscriptionId,
            )
            .toList();
        final favoritesHeader = find.byKey(
          const ValueKey('server-group-favorites'),
        );
        final paidHeader = find.byKey(
          ValueKey('server-group-source-${paid.first.subscriptionId}'),
        );

        List<int> visibleIds() => tester
            .widgetList<ServerListTile>(find.byType(ServerListTile))
            .map((tile) => tile.server.id)
            .toList();
        void expectStatePreserved() {
          final current = container.read(serversNotifierProvider).requireValue;
          expect(current, hasLength(original.length));
          expect({
            for (final server in current) server.id: server.subscriptionId,
          }, sources);
          expect(container.read(selectedServerProvider)!.id, selected);
          expect(visibleIds().toSet(), hasLength(visibleIds().length));
        }

        expect(find.text(strings.favoritesTitle), findsNothing);
        expect(visibleIds(), original.map((s) => s.id));
        await openMenu(tester, paid.last.id);
        await tester.tap(find.text(strings.addToFavorites));
        await tester.pumpAndSettle();
        expect(find.text(strings.favoritesTitle), findsOneWidget);
        expect(
          find.descendant(of: favoritesHeader, matching: find.text('1')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: paidHeader, matching: find.text('1')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: favoritesHeader,
            matching: find.byIcon(Icons.star_rounded),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: favoritesHeader,
            matching: find.byType(PopupMenuButton<bool>),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: favoritesHeader,
            matching: find.byIcon(Icons.delete_sweep_outlined),
          ),
          findsNothing,
        );
        expect(visibleIds(), [
          paid.last.id,
          ...original.where((s) => s.id != paid.last.id).map((s) => s.id),
        ]);
        expect(
          tester.getTopLeft(find.text(strings.favoritesTitle)).dy,
          lessThan(tester.getTopLeft(find.byType(ServerListTile).first).dy),
        );
        expectStatePreserved();

        // A source group still owns every saved profile from that feed,
        // including the row currently presented under Favorites.
        await openGroupDelete(tester, paidHeader, home: home);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(strings.deleteGroupContent(paid.length, true)),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(strings.cancelButton),
          ),
        );
        await tester.pumpAndSettle();
        expectStatePreserved();

        await openMenu(tester, paid.first.id);
        await tester.tap(find.text(strings.addToFavorites));
        await tester.pumpAndSettle();
        expect(visibleIds(), [...paid.map((s) => s.id), original.first.id]);
        expect(
          find.descendant(of: favoritesHeader, matching: find.text('2')),
          findsOneWidget,
        );
        expect(find.text('HoneyVPN · Plus'), findsNothing);
        expectStatePreserved();

        // Favorites are a presentation group: collapsing them does not hide
        // unrelated profiles, change the saved feed, or alter selection.
        await tester.tap(find.text(strings.favoritesTitle));
        await tester.pumpAndSettle();
        expect(visibleIds(), [original.first.id]);
        expectStatePreserved();
        await tester.tap(find.text(strings.favoritesTitle));
        await tester.pumpAndSettle();
        expect(visibleIds(), [...paid.map((s) => s.id), original.first.id]);

        await openMenu(tester, paid.last.id);
        await tester.tap(find.text(strings.removeFromFavorites));
        await tester.pumpAndSettle();
        expect(find.text('HoneyVPN · Plus'), findsOneWidget);
        expect(
          find.descendant(of: favoritesHeader, matching: find.text('1')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: paidHeader, matching: find.text('1')),
          findsOneWidget,
        );
        expect(visibleIds(), [paid.first.id, original.first.id, paid.last.id]);
        expectStatePreserved();
        await openMenu(tester, paid.first.id);
        await tester.tap(find.text(strings.removeFromFavorites));
        await tester.pumpAndSettle();
        expect(find.text(strings.favoritesTitle), findsNothing);
        expect(visibleIds(), original.map((s) => s.id));
        expectStatePreserved();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      '${home ? 'home' : 'servers'} deleting a manual group includes its favorite and preserves other feeds',
      (tester) async {
        final container = await renderMainList(tester, home);
        final notifier = container.read(serversNotifierProvider.notifier);
        final original = container.read(serversNotifierProvider).requireValue;
        final selected = container.read(selectedServerProvider)!.id;
        await notifier.addFromProxies(
          const LinkDispatcher().dispatchMultiple(
            'vless://manual-first@first.example.invalid:443?security=tls#First\n'
            'vless://manual-second@second.example.invalid:443?security=tls#Second',
          ),
        );
        await tester.pumpAndSettle();
        final manual = container
            .read(serversNotifierProvider)
            .requireValue
            .where((server) => server.subscriptionId.isEmpty)
            .toList();
        expect(manual, hasLength(2));
        await openMenu(tester, manual.first.id);
        await tester.tap(find.text(const S('ru').addToFavorites));
        await tester.pumpAndSettle();
        await container
            .read(connectionNotifierProvider.notifier)
            .connect(manual.first);
        await tester.pumpAndSettle();
        expect(container.read(connectionNotifierProvider).isConnected, isTrue);
        final manualHeader = find.byKey(const ValueKey('server-group-source-'));
        expect(
          find.descendant(of: manualHeader, matching: find.text('1')),
          findsOneWidget,
        );
        expect(find.text(const S('ru').favoritesTitle), findsOneWidget);

        await openGroupDelete(tester, manualHeader, home: home);
        final dialog = find.byType(AlertDialog);
        expect(
          find.descendant(
            of: dialog,
            matching: find.text(const S('ru').deleteGroupContent(2, false)),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(
            of: dialog,
            matching: find.widgetWithText(
              FilledButton,
              const S('ru').deleteButton,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          container
              .read(serversNotifierProvider)
              .requireValue
              .map((server) => server.toJson()),
          original.map((server) => server.toJson()),
        );
        expect(container.read(selectedServerProvider)!.id, selected);
        expect(container.read(connectionNotifierProvider).isConnected, isFalse);
        expect(manualHeader, findsNothing);
        expect(find.text(const S('ru').favoritesTitle), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
