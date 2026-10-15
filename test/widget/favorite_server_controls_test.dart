import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/presentation/screens/home_screen.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/server_selector_chip.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
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
      await tester.tap(find.byType(ServerSelectorChip));
      await tester.pumpAndSettle();
      expect(find.text(const S('ru').favoritesTitle), findsOneWidget);
      final row = find.byKey(ValueKey('choose-server-${favorite.id}'));
      expect(row, findsOneWidget);
      for (final server in all.where((server) => server.id != favorite.id)) {
        final other = find.byKey(ValueKey('choose-server-${server.id}'));
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
}
