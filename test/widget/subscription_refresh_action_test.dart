import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/subscriptions/data/models/subscription_model.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/presentation/widgets/subscription_refresh_action.dart';

class _Subscriptions extends SubscriptionsNotifier {
  final request = Completer<void>();
  var calls = 0;
  @override
  Future<SubscriptionsState> build() async => const SubscriptionsState(
    subs: [
      SubscriptionModel(id: 1, url: 'https://one.example.invalid', name: 'One'),
      SubscriptionModel(id: 2, url: 'https://two.example.invalid', name: 'Two'),
    ],
  );
  @override
  Future<void> refreshAll() async {
    calls++;
    await request.future;
  }

  void automatic(Set<int> ids) =>
      state = AsyncData(state.requireValue.copyWith(refreshing: ids));
}

Widget app(
  _Subscriptions notifier, {
  bool reduced = false,
  bool accessible = false,
}) => ProviderScope(
  overrides: [
    subscriptionsProvider.overrideWith(() => notifier),
    stringsProvider.overrideWithValue(const S('en')),
  ],
  child: MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: reduced, accessibleNavigation: accessible),
      child: child!,
    ),
    home: const Scaffold(
      body: Row(
        children: [
          SubscriptionRefreshAction(key: ValueKey('all')),
          SubscriptionRefreshAction(key: ValueKey('one'), subscriptionId: 1),
          SubscriptionRefreshAction(key: ValueKey('two'), subscriptionId: 2),
        ],
      ),
    ),
  ),
);

IconButton button(WidgetTester tester, String key) => tester.widget(
  find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(IconButton),
  ),
);
RotationTransition rotation(WidgetTester tester, String key) => tester.widget(
  find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(RotationTransition),
  ),
);

void main() {
  testWidgets(
    'rotation lasts entire awaited refresh, repeat blocked, error releases action',
    (tester) async {
      final notifier = _Subscriptions();
      await tester.pumpWidget(app(notifier));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(rotation(tester, 'all').turns.value, lessThan(0));
      expect(button(tester, 'all').onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('all')));
      await tester.pump();
      expect(notifier.calls, 1);
      notifier.request.completeError(StateError('Synthetic update failed'));
      await tester.pumpAndSettle();
      expect(rotation(tester, 'all').turns.value, 0);
      expect(button(tester, 'all').onPressed, isNotNull);
      expect(find.text(const S('en').subscriptionUpdateFailed), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
  for (final (reduced, accessible) in [
    (false, false),
    (false, true),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      'automatic batch respects reduced motion $reduced with screen reader $accessible',
      (tester) async {
        final notifier = _Subscriptions();
        await tester.pumpWidget(
          app(notifier, reduced: reduced, accessible: accessible),
        );
        await tester.pumpAndSettle();
        notifier.automatic({1, 2});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(button(tester, 'all').onPressed, isNull);
        expect(button(tester, 'one').onPressed, isNull);
        expect(button(tester, 'two').onPressed, isNull);
        for (final key in ['all', 'one', 'two']) {
          expect(rotation(tester, key).turns.value, reduced ? 0 : lessThan(0));
        }
        notifier.automatic({2});
        await tester.pump();
        expect(button(tester, 'all').onPressed, isNull);
        expect(button(tester, 'one').onPressed, isNotNull);
        notifier.automatic({});
        await tester.pumpAndSettle();
        expect(button(tester, 'all').onPressed, isNotNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
}
