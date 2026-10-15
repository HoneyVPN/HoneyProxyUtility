import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/app/app.dart';
import 'package:honeyproxyutility/app/app_theme.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/presentation/widgets/connect_button.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import '../support/design_preview.dart' as preview;

void main() {
  testWidgets('Connect supports screen reader activation and Enter', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      var activations = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [stringsProvider.overrideWithValue(const S('en'))],
          child: MaterialApp(
            theme: honeyThemeLight,
            home: Scaffold(
              body: ConnectButton(
                status: ConnectionStatus.disconnected,
                onTap: () => activations++,
              ),
            ),
          ),
        ),
      );
      expect(
        tester
            .getSemantics(find.byType(FilledButton))
            .getSemanticsData()
            .hasAction(ui.SemanticsAction.tap),
        isTrue,
      );
      Focus.of(tester.element(find.text('Connect'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(activations, 1);
    } finally {
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('production app tolerates view focus before its first layout', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      tester.binding.attachRootWidget(
        tester.binding.wrapWithDefaultView(
          preview.designPreviewScope(child: const HoneyProxyApp()),
        ),
      );
      tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ui.ViewFocusState.focused,
          direction: ui.ViewFocusDirection.forward,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConnectButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}
