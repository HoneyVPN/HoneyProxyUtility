import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_auto_send.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_journal.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_report.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_upload.dart';
import 'package:honeyproxyutility/features/diagnostics/presentation/diagnostic_auto_send_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingUploader extends DiagnosticUploader {
  _CountingUploader() : super(demo: true);
  int calls = 0;

  @override
  Future<String> send(DiagnosticReport report) async {
    calls++;
    return report.data['requestId'] as String;
  }
}

class _Fixture {
  _Fixture(this.preferences, this.controller, this.uploader);
  final SharedPreferences preferences;
  final DiagnosticAutoSendController controller;
  final _CountingUploader uploader;
  int vpnActions = 0;
  int reportsBuilt = 0;
  final platformCalls = <String>[];

  static Future<_Fixture> create({bool alreadyEnabled = false}) async {
    SharedPreferences.setMockInitialValues({
      if (alreadyEnabled)
        DiagnosticAutoSendController.consentKey: jsonEncode({
          'enabled': true,
          'asked': true,
        }),
      // Previous VPN disclosure acceptance must never consent to diagnostics.
      'vpn_disclosure_accepted': true,
      'vpn_disclosure_accepted_v2': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final uploader = _CountingUploader();
    late _Fixture fixture;
    final controller = DiagnosticAutoSendController(
      preferences: preferences,
      uploader: uploader,
      journal: DiagnosticJournal(persist: false),
      isForeground: () => true,
      buildReport: () async {
        fixture.reportsBuilt++;
        return DiagnosticReport({
          'requestId': '11111111111111111111111111111111',
          'events': <Object>[],
        });
      },
    );
    fixture = _Fixture(preferences, controller, uploader);
    await controller.initialize();
    return fixture;
  }

  Widget widget(String locale) => ProviderScope(
    overrides: [
      stringsProvider.overrideWithValue(S(locale)),
      diagnosticAutoControllerProvider.overrideWithValue(controller),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const AutomaticDiagnosticsTile(),
            TextButton(
              key: const ValueKey('independent-vpn-action'),
              onPressed: () => vpnActions++,
              child: const Text('VPN'),
            ),
          ],
        ),
      ),
    ),
  );

  Map<String, dynamic> get persistedConsent =>
      jsonDecode(
            preferences.getString(DiagnosticAutoSendController.consentKey)!,
          )
          as Map<String, dynamic>;

  void dispose() {
    controller.dispose();
    uploader.dispose();
  }
}

Finder get _tile => find.byType(SwitchListTile);
bool _enabled(WidgetTester tester) =>
    tester.widget<SwitchListTile>(_tile).value;

void main() {
  const vpnChannel = MethodChannel('ru.honeyvpn.proxy/vpn');

  for (final locale in ['ru', 'en']) {
    final title = locale == 'ru'
        ? 'Помочь исправлять ошибки?'
        : 'Help us fix errors?';
    final allow = locale == 'ru'
        ? 'Разрешить автоотправку'
        : 'Allow automatic reports';
    final decline = locale == 'ru' ? 'Нет, спасибо' : 'No, thanks';

    testWidgets(
      'opening diagnostics and declining opt-in keeps VPN usable ($locale)',
      (tester) async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(vpnChannel, (call) async {
              fixture.platformCalls.add(call.method);
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(vpnChannel, null),
        );
        await tester.pumpWidget(fixture.widget(locale));
        await tester.pumpAndSettle();
        expect(_enabled(tester), isFalse);
        expect(fixture.controller.consent.enabled, isFalse);
        expect(fixture.uploader.calls, 0);
        expect(fixture.reportsBuilt, 0);
        expect(find.byType(AlertDialog), findsNothing);

        await tester.tap(_tile);
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget);
        expect(find.textContaining('api.honeyvpn.ru'), findsOneWidget);
        expect(
          find.textContaining(locale == 'ru' ? 'семи суток' : 'seven days'),
          findsOneWidget,
        );
        expect(_enabled(tester), isFalse);
        expect(fixture.controller.consent.enabled, isFalse);
        expect(fixture.uploader.calls, 0);
        await tester.tap(find.widgetWithText(TextButton, decline));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(_enabled(tester), isFalse);
        expect(fixture.controller.consent.enabled, isFalse);
        await tester.tap(find.byKey(const ValueKey('independent-vpn-action')));
        await tester.pumpAndSettle();
        expect(fixture.vpnActions, 1);
        expect(fixture.uploader.calls, 0);
        expect(fixture.platformCalls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'affirmative opt-in persists without uploading on acceptance ($locale)',
      (tester) async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        await tester.pumpWidget(fixture.widget(locale));
        await tester.pumpAndSettle();
        await tester.tap(_tile);
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget);
        expect(
          fixture.preferences.getString(
            DiagnosticAutoSendController.consentKey,
          ),
          isNull,
        );
        final button = find.widgetWithText(FilledButton, allow);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(fixture.controller.consent.enabled, isTrue);
        expect(fixture.persistedConsent, {'enabled': true, 'asked': true});
        expect(_enabled(tester), isTrue);
        expect(fixture.uploader.calls, 0);
        expect(fixture.reportsBuilt, 0);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'disable needs no permission or second dialog and can be declined again ($locale)',
      (tester) async {
        final fixture = await _Fixture.create(alreadyEnabled: true);
        addTearDown(fixture.dispose);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(vpnChannel, (call) async {
              fixture.platformCalls.add(call.method);
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(vpnChannel, null),
        );
        await tester.pumpWidget(fixture.widget(locale));
        await tester.pumpAndSettle();
        expect(_enabled(tester), isTrue);
        await tester.tap(_tile);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(_enabled(tester), isFalse);
        expect(fixture.persistedConsent, {'enabled': false, 'asked': true});
        expect(fixture.platformCalls, isEmpty);
        expect(fixture.uploader.calls, 0);

        await tester.tap(_tile);
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, decline));
        await tester.pumpAndSettle();
        expect(_enabled(tester), isFalse);
        expect(fixture.persistedConsent, {'enabled': false, 'asked': true});
        expect(fixture.uploader.calls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'startup gate offers optional consent once and remembers refusal',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final uploader = _CountingUploader();
      addTearDown(uploader.dispose);
      var vpnActions = 0;
      Widget app() {
        final navigatorKey = GlobalKey<NavigatorState>();
        return ProviderScope(
          overrides: [
            stringsProvider.overrideWithValue(const S('en')),
            diagnosticUploaderProvider.overrideWithValue(uploader),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            builder: (_, child) => DiagnosticAutoSendGate(
              navigatorKey: navigatorKey,
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  const AutomaticDiagnosticsTile(),
                  TextButton(
                    key: const ValueKey('startup-vpn-action'),
                    onPressed: () => vpnActions++,
                    child: const Text('VPN'),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('Help us fix errors?'), findsOneWidget);
      expect(uploader.calls, 0);
      await tester.tap(find.widgetWithText(TextButton, 'No, thanks'));
      await tester.pumpAndSettle();
      final preferences = await SharedPreferences.getInstance();
      expect(
        jsonDecode(
          preferences.getString(DiagnosticAutoSendController.consentKey)!,
        ),
        {'enabled': false, 'asked': true},
      );
      await tester.tap(find.byKey(const ValueKey('startup-vpn-action')));
      await tester.pumpAndSettle();
      expect(vpnActions, 1);
      expect(_enabled(tester), isFalse);
      expect(uploader.calls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(_enabled(tester), isFalse);
      expect(uploader.calls, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
