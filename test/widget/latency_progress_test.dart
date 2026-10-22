import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/servers/presentation/widgets/country_presentation.dart';
import 'package:honeyproxyutility/features/servers/presentation/widgets/latency_test_action.dart';
import 'package:honeyproxyutility/features/servers/presentation/widgets/server_list_tile.dart';

final _profiles = List.generate(
  3,
  (index) => ServerProfileModel(
    id: index + 1,
    protocol: 'vless',
    name: 'NL Netherlands',
    host: 'example.invalid',
    port: 443,
    configJson: '{}',
    subscriptionId: '',
    addedAt: DateTime(2026),
  ),
);

class _Servers extends ServersNotifier {
  final done = Completer<void>();
  var checks = 0;
  var cancellations = 0;

  @override
  Future<List<ServerProfileModel>> build() async => _profiles;

  void progress(int completed, Set<int> activeIds, {bool running = true}) {
    ref
        .read(latencyTestProgressProvider.notifier)
        .update(
          LatencyTestProgress(
            isRunning: running,
            completed: completed,
            total: _profiles.length,
            activeIds: activeIds,
          ),
        );
  }

  @override
  Future<void> testAllLatency() {
    checks++;
    progress(0, {1, 2});
    return done.future;
  }

  @override
  Future<void> cancelLatencyTests() async {
    cancellations++;
    progress(1, {}, running: false);
    done.complete();
  }
}

Widget _app(_Servers notifier, {Widget? child}) => ProviderScope(
  overrides: [
    serversNotifierProvider.overrideWith(() => notifier),
    stringsProvider.overrideWithValue(const S('en')),
  ],
  child: MaterialApp(home: Scaffold(body: child ?? const LatencyTestAction())),
);

void main() {
  testWidgets(
    'batch indicator keeps animating after results and still cancels',
    (tester) async {
      final notifier = _Servers();
      await tester.pumpWidget(_app(notifier));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(const S('en').pingAllTooltip));
      await tester.pump();
      final indicator = find.byType(CircularProgressIndicator);
      final originalState = tester.state(indicator);

      for (var completed = 1; completed < 3; completed++) {
        notifier.progress(completed, {3});
        await tester.pump();
        expect(
          tester.widget<CircularProgressIndicator>(indicator).value,
          isNull,
        );
        expect(tester.state(indicator), same(originalState));
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.value ==
                    const S('en').latencyProgress(completed, 3),
          ),
          findsOneWidget,
        );
        final paint = find.descendant(
          of: indicator,
          matching: find.byType(CustomPaint),
        );
        final before = tester.widget<CustomPaint>(paint).painter!;
        await tester.pump(const Duration(milliseconds: 200));
        final after = tester.widget<CustomPaint>(paint).painter!;
        expect(after.shouldRepaint(before), isTrue);
      }

      await tester.tap(find.byTooltip(const S('en').cancelLatencyTest));
      await tester.pumpAndSettle();
      expect(notifier.checks, 1);
      expect(notifier.cancellations, 1);
      expect(indicator, findsNothing);
      expect(find.byTooltip(const S('en').pingAllTooltip), findsOneWidget);
    },
  );

  testWidgets('row only rebuilds when its own active ping status changes', (
    tester,
  ) async {
    final notifier = _Servers();
    await tester.pumpWidget(
      _app(
        notifier,
        child: ServerListTile(
          server: _profiles.first,
          isSelected: false,
          onTap: () {},
          onDelete: () {},
          onTapDetail: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    ProviderScope.containerOf(
      tester.element(find.byType(ServerListTile)),
    ).read(serversNotifierProvider.notifier);
    final flag = find.byType(CountryFlagIcon);
    final idleFlag = tester.widget<CountryFlagIcon>(flag);
    notifier.progress(0, {2});
    await tester.pump();
    expect(tester.widget<CountryFlagIcon>(flag), same(idleFlag));
    expect(find.byType(CircularProgressIndicator), findsNothing);

    notifier.progress(0, {1, 2});
    await tester.pump();
    final activeFlag = tester.widget<CountryFlagIcon>(flag);
    expect(activeFlag, isNot(same(idleFlag)));
    final indicator = find.byType(CircularProgressIndicator);
    final originalState = tester.state(indicator);

    notifier.progress(1, {1, 3});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<CountryFlagIcon>(flag), same(activeFlag));
    expect(tester.state(indicator), same(originalState));
    notifier.progress(3, {}, running: false);
    await tester.pumpAndSettle();
    expect(indicator, findsNothing);
  });
}
