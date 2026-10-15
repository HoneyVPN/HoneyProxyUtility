import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/app/shell_scaffold.dart';

void main() {
  testWidgets('mobile navigation is localized and switches to settings', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    GoRouter? router;
    try {
      router = await _render(tester, width: 393, locale: 'ru');
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-sidebar')), findsNothing);
      for (final label in ['Подключение', 'Импорт', 'Каталог', 'Настройки']) {
        expect(
          find.semantics
              .byLabel(RegExp(label))
              .evaluate()
              .any(
                (node) =>
                    node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
              ),
          isTrue,
        );
      }
      await tester.tap(find.byIcon(Icons.tune_outlined));
      await tester.pumpAndSettle();
      expect(find.text('screen-/settings'), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      router?.dispose();
    }
  });

  testWidgets('wide display uses a rail with English destinations', (
    tester,
  ) async {
    final router = await _render(tester, width: 1100, locale: 'en');
    addTearDown(router.dispose);
    expect(find.byKey(const ValueKey('desktop-sidebar')), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Connection'), findsOneWidget);
    final sidebar = tester.getRect(
      find.byKey(const ValueKey('desktop-sidebar')),
    );
    expect(sidebar, const Rect.fromLTWH(0, 0, 200, 700));
    final item = tester.getSize(find.widgetWithText(InkWell, 'Connection'));
    expect(item.height, inInclusiveRange(36, 40));
    await tester.tap(find.byIcon(CupertinoIcons.tray_arrow_down));
    await tester.pumpAndSettle();
    expect(find.text('screen-/converter'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small display with large text retains usable navigation', (
    tester,
  ) async {
    final router = await _render(tester, width: 320, locale: 'ru', scale: 2);
    addTearDown(router.dispose);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.storefront_outlined));
    await tester.pumpAndSettle();
    expect(find.text('screen-/marketplace'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('desktop Command shortcuts navigate and collapse the sidebar', (
    tester,
  ) async {
    final router = await _render(tester, width: 1100, locale: 'en');
    addTearDown(router.dispose);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.text('screen-/settings'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('desktop-sidebar'))).width,
      60,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.text('screen-/converter'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'all desktop destinations remain in the accessibility tree around the nested navigator',
    (tester) async {
      final semantics = tester.ensureSemantics();
      GoRouter? router;
      try {
        router = await _render(tester, width: 1100, locale: 'en');
        for (final label in ['Connection', 'Import', 'Providers', 'Settings']) {
          final nodes = find.semantics.byLabel(RegExp(label)).evaluate();
          expect(
            nodes.any(
              (node) =>
                  node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
            ),
            isTrue,
            reason: '$label must be reachable and actionable by VoiceOver',
          );
          final actionable = nodes
              .where(
                (node) =>
                    node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
              )
              .toList();
          expect(actionable, hasLength(1));
          expect(actionable.single.getSemanticsData().label, label);
        }
        await tester.tap(find.byIcon(CupertinoIcons.tray_arrow_down));
        await tester.pumpAndSettle();
        expect(find.text('screen-/converter'), findsOneWidget);
        expect(
          find.semantics
              .byLabel(RegExp('Settings'))
              .evaluate()
              .any(
                (node) =>
                    node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
              ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        router?.dispose();
      }
    },
  );
}

Future<GoRouter> _render(
  WidgetTester tester, {
  required double width,
  required String locale,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [
      ShellRoute(
        builder: (_, __, child) => ShellScaffold(child: child),
        routes: [
          for (final path in ['/', '/converter', '/marketplace', '/settings'])
            GoRoute(
              path: path,
              builder: (_, __) => Center(child: Text('screen-$path')),
            ),
        ],
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [stringsProvider.overrideWithValue(S(locale))],
      child: MaterialApp.router(
        theme: honeyThemeLight,
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(
            size: Size(width, 700),
            textScaler: TextScaler.linear(scale),
          ),
          child: Theme(
            data: honeyThemeForWidth(Theme.of(context), width),
            child: child!,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
