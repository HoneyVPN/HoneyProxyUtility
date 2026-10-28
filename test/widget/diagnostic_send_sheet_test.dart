import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_report.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_upload.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/log_screen.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import '../support/design_preview.dart';

void main() {
  testWidgets('RU/EN explicit diagnostics review and demo never uploads', (
    tester,
  ) async {
    final uploader = _CountingDemoUploader();
    addTearDown(uploader.dispose);
    await tester.pumpWidget(
      designPreviewScope(
        child: ProviderScope(
          overrides: [diagnosticUploaderProvider.overrideWithValue(uploader)],
          child: const MaterialApp(home: LogScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Демо: отчёт не отправлен.'), findsNothing);
    await tester.tap(find.byTooltip('Отправить диагностику'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Этот отчёт отправится после нажатия кнопки.'),
      findsOneWidget,
    );
    expect(find.textContaining('Приложение пытается скрыть'), findsOneWidget);
    expect(
      find.textContaining('Не вводите пароли, ссылки подписок и личные данные'),
      findsOneWidget,
    );
    final ruPrivacy = find.widgetWithText(
      TextButton,
      'Политика конфиденциальности',
    );
    expect(ruPrivacy, findsOneWidget);
    await tester.ensureVisible(ruPrivacy);
    await tester.pumpAndSettle();
    expect(ruPrivacy.hitTestable(), findsOneWidget);
    expect(find.textContaining('0 событий'), findsOneWidget);
    expect(uploader.sendCalls, 0);
    expect(find.text('DEMO-LOCAL'), findsNothing);
    await tester.ensureVisible(find.text('Отправить в поддержку'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отправить в поддержку'));
    await tester.pumpAndSettle();
    expect(uploader.sendCalls, 1);
    expect(find.text('Демо: отчёт не отправлен.'), findsOneWidget);
    expect(find.text('DEMO-LOCAL'), findsOneWidget);
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LogScreen)),
    );
    await container.read(settingsProvider.notifier).setLocale('en');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send diagnostics'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This report is sent after you press the button.'),
      findsOneWidget,
    );
    expect(find.textContaining('The app attempts to hide'), findsOneWidget);
    expect(
      find.textContaining(
        'Do not enter passwords, subscription URLs or personal details',
      ),
      findsOneWidget,
    );
    final enPrivacy = find.widgetWithText(TextButton, 'Privacy policy');
    expect(enPrivacy, findsOneWidget);
    await tester.ensureVisible(enPrivacy);
    await tester.pumpAndSettle();
    expect(enPrivacy.hitTestable(), findsOneWidget);
    expect(find.text('Send to support'), findsOneWidget);
    expect(uploader.sendCalls, 1);
    expect(find.text('DEMO-LOCAL'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _CountingDemoUploader extends DiagnosticUploader {
  _CountingDemoUploader() : super(demo: true);

  int sendCalls = 0;

  @override
  Future<String> send(DiagnosticReport report) {
    sendCalls++;
    return super.send(report);
  }
}
