import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/settings/presentation/screens/log_screen.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import '../support/design_preview.dart';

void main() {
  testWidgets('RU/EN explicit diagnostics review and demo never uploads', (
    tester,
  ) async {
    await tester.pumpWidget(
      designPreviewScope(child: const MaterialApp(home: LogScreen())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Демо: отчёт не отправлен.'), findsNothing);
    await tester.tap(find.byTooltip('Отправить диагностику'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Ничего не отправляется автоматически.'),
      findsOneWidget,
    );
    expect(find.textContaining('0 событий'), findsOneWidget);
    await tester.tap(find.text('Отправить в поддержку'));
    await tester.pumpAndSettle();
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
      find.textContaining('Nothing is sent automatically.'),
      findsOneWidget,
    );
    expect(find.text('Send to support'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
