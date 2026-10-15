import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/settings/data/log_provider.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/log_screen.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );

  for (final locale in ['ru', 'en']) {
    testWidgets('$locale Logs reports copied only after clipboard completes', (
      tester,
    ) async {
      final completed = Completer<Object?>();
      Object? payload;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) {
        if (call.method != 'Clipboard.setData') return Future.value();
        payload = call.arguments;
        return completed.future;
      });
      final strings = S(locale);
      await _render(tester, strings);
      await tester.tap(find.byTooltip(locale == 'ru' ? 'Копировать' : 'Copy'));
      await tester.pump();
      expect(payload, {'text': '12:34:56  synthetic connection event'});
      expect(find.text(strings.copied), findsNothing);
      expect(find.text(strings.copyFailed), findsNothing);
      completed.complete();
      await tester.pumpAndSettle();
      expect(find.text(strings.copied), findsOneWidget);
      expect(find.text(strings.copyFailed), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '$locale Logs clipboard failure shows safe feedback without success',
      (tester) async {
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(
              code: 'clipboard_unavailable',
              message: 'synthetic-private-platform-detail',
            );
          }
          return null;
        });
        final strings = S(locale);
        await _render(tester, strings);
        await tester.tap(
          find.byTooltip(locale == 'ru' ? 'Копировать' : 'Copy'),
        );
        await tester.pumpAndSettle();
        expect(find.text(strings.copyFailed), findsOneWidget);
        expect(find.text(strings.copied), findsNothing);
        expect(find.textContaining('synthetic-private'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final fail in [false, true]) {
    testWidgets(
      'clipboard ${fail ? "failure" : "success"} after leaving Logs does not access disposed UI',
      (tester) async {
        final completed = Completer<Object?>();
        messenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) => call.method == 'Clipboard.setData'
              ? completed.future
              : Future.value(),
        );
        await _render(tester, const S('en'));
        await tester.tap(find.byTooltip('Copy'));
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        if (fail) {
          completed.completeError(
            PlatformException(code: 'clipboard_unavailable'),
          );
        } else {
          completed.complete();
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _render(WidgetTester tester, S strings) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stringsProvider.overrideWithValue(strings),
        logProvider.overrideWith((_) => _SyntheticLogs()),
      ],
      child: const MaterialApp(home: LogScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

class _SyntheticLogs extends LogNotifier {
  _SyntheticLogs() {
    state = [
      LogEntry(
        time: DateTime(2026, 10, 15, 12, 34, 56),
        message: 'synthetic connection event',
      ),
    ];
  }
}
