import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/features/settings/presentation/widgets/yunicode_credit.dart';

const _link = ValueKey('yunicode-website-link');

void main() {
  testWidgets('theme changes keep the revealed signature readable and usable', (
    tester,
  ) async {
    var brightness = Brightness.dark;
    var opens = 0;
    late StateSetter update;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Theme(
                data: ThemeData(brightness: brightness),
                child: MediaQuery(
                  data: const MediaQueryData(disableAnimations: true),
                  child: YuNiCodeCredit(
                    caption: 'Developed by',
                    onOpenWebsite: () async => opens++,
                  ),
                ),
              );
            },
          ),
        ),
      );
      final state = tester.state(find.byType(YuNiCodeCredit));
      await tester.tap(find.byKey(_link));
      await tester.pumpAndSettle();
      final bounds = tester.getRect(find.byKey(_link));
      for (final next in [Brightness.dark, Brightness.light, Brightness.dark]) {
        update(() => brightness = next);
        await tester.pumpAndSettle();
        final surface = tester.widget<ColoredBox>(
          find.descendant(
            of: find.byType(YuNiCodeCredit),
            matching: find.byType(ColoredBox),
          ),
        );
        final foreground = tester.widget<Text>(find.text('Yu')).style!.color!;
        final lighter = foreground.computeLuminance();
        final darker = surface.color.computeLuminance();
        final contrast = lighter > darker
            ? (lighter + .05) / (darker + .05)
            : (darker + .05) / (lighter + .05);
        expect(
          contrast,
          greaterThan(7),
          reason: 'The wordmark must stay legible.',
        );
        expect(
          surface.color.computeLuminance(),
          next == Brightness.dark ? lessThan(.05) : greaterThan(.7),
        );
        expect(tester.state(find.byType(YuNiCodeCredit)), same(state));
        expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
        expect(tester.getRect(find.byKey(_link)), bounds);
        expect(
          opens,
          0,
          reason: 'Changing appearance must not activate the link.',
        );
      }
      await tester.tap(find.byKey(_link));
      await tester.pumpAndSettle();
      expect(
        opens,
        1,
        reason: 'The existing reveal state survives theme changes.',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester);
    }
  });

  testWidgets('touch reveals the signature before opening its website', (
    tester,
  ) async {
    var opens = 0;
    try {
      await _render(tester, onOpen: () async => opens++);
      // The resting footer must not keep unrelated screen tests animating.
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      final bounds = tester.getRect(find.byKey(_link));
      expect(bounds.height, greaterThanOrEqualTo(44));
      await tester.tap(find.byKey(_link));
      await tester.pump(const Duration(milliseconds: 1200));
      expect(opens, 0);
      expect(tester.getRect(find.byKey(_link)), bounds);
      await tester.tap(find.byKey(_link));
      await tester.pump();
      expect(opens, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester);
    }
  });

  testWidgets('keyboard focus reveals the link and Enter or Space opens it', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var opens = 0;
    try {
      await _render(tester, onOpen: () async => opens++);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump(const Duration(milliseconds: 1200));
      expect(
        tester
            .getSemantics(find.byKey(_link))
            .getSemanticsData()
            .flagsCollection
            .isFocused,
        ui.Tristate.isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opens, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(opens, 2);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      await _dispose(tester);
    }
  });

  testWidgets('screen reader has one named actionable link in either state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var opens = 0;
    try {
      await _render(tester, reduceMotion: true, onOpen: () async => opens++);
      final node = tester.getSemantics(find.byKey(_link));
      final data = node.getSemanticsData();
      expect(data.label, 'YuNiCode');
      expect(data.flagsCollection.isLink, isTrue);
      expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
      expect(find.bySemanticsLabel('YuNiCode'), findsOneWidget);
      tester.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          nodeId: node.id,
          viewId: tester.view.viewId,
          type: ui.SemanticsAction.tap,
        ),
      );
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.tap(find.byKey(_link));
      await tester.pumpAndSettle();
      tester.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          nodeId: node.id,
          viewId: tester.view.viewId,
          type: ui.SemanticsAction.tap,
        ),
      );
      await tester.pumpAndSettle();
      expect(opens, 2);
      expect(find.bySemanticsLabel('YuNiCode'), findsOneWidget);
    } finally {
      semantics.dispose();
      await _dispose(tester);
    }
  });

  testWidgets('mouse hover reveals a usable link and stops motion on exit', (
    tester,
  ) async {
    var opens = 0;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    try {
      await _render(tester, onOpen: () async => opens++);
      await mouse.addPointer(location: Offset.zero);
      final position = tester.getCenter(find.byKey(_link));
      await mouse.moveTo(position);
      await tester.pump(const Duration(milliseconds: 1200));
      await mouse.down(position);
      await mouse.up();
      await tester.pump();
      expect(opens, 1, reason: 'Hover already revealed the brand.');
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await mouse.removePointer();
      await _dispose(tester);
    }
  });

  testWidgets('narrow large text and reduced motion remain operable', (
    tester,
  ) async {
    var opens = 0;
    try {
      await _render(
        tester,
        width: 288,
        scale: 3,
        reduceMotion: true,
        onOpen: () async => opens++,
      );
      await tester.tap(find.byKey(_link));
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(_link));
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester);
    }
  });

  testWidgets('an expanded signature does not animate an inactive route', (
    tester,
  ) async {
    var enabled = true;
    late StateSetter update;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: TickerMode(
                  enabled: enabled,
                  child: YuNiCodeCredit(
                    caption: 'Приложение разработал',
                    onOpenWebsite: () async {},
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.byKey(_link));
      await tester.pump(const Duration(milliseconds: 1200));
      update(() => enabled = false);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester);
    }
  });

  testWidgets('a missing website handler reports a localized message', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      for (final caption in ['Приложение разработал', 'Developed by']) {
        await _render(
          tester,
          caption: caption,
          reduceMotion: true,
          onOpen: () async => throw PlatformException(code: 'unavailable'),
        );
        final node = tester.getSemantics(find.byKey(_link));
        tester.binding.performSemanticsAction(
          ui.SemanticsActionEvent(
            nodeId: node.id,
            viewId: tester.view.viewId,
            type: ui.SemanticsAction.tap,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            caption == 'Developed by'
                ? 'Could not open the website'
                : 'Не удалось открыть сайт',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await _dispose(tester);
      }
    } finally {
      semantics.dispose();
      await _dispose(tester);
    }
  });
}

Future<void> _render(
  WidgetTester tester, {
  required Future<void> Function() onOpen,
  double width = 400,
  double scale = 1,
  bool reduceMotion = false,
  String caption = 'Приложение разработал',
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: MediaQuery(
          data: MediaQueryData(
            disableAnimations: reduceMotion,
            textScaler: TextScaler.linear(scale),
          ),
          child: SizedBox(
            width: width,
            child: YuNiCodeCredit(caption: caption, onOpenWebsite: onOpen),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}
