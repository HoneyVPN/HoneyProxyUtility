import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_auto_send.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_journal.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_report.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_upload.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('default and old VPN consent never build or send reports', () async {
    SharedPreferences.setMockInitialValues({'vpn_disclosure_accepted': true});
    final harness = _Harness();
    await harness.controller.initialize();
    harness.journal.add('app', 'error handshake', error: true);
    await _flush();

    expect(harness.controller.consent.enabled, isFalse);
    expect(harness.controller.consent.asked, isFalse);
    expect(harness.builds, 0);
    expect(harness.uploader.calls, 0);
  });

  test(
    'not now persists asked without enabling and emits consent changes',
    () async {
      final harness = _Harness();
      final changes = <DiagnosticAutoConsent>[];
      final subscription = harness.controller.consentChanges.listen(
        changes.add,
      );
      addTearDown(subscription.cancel);
      await harness.controller.initialize();
      await harness.controller.markAsked();
      await _flush();

      expect(changes.last.enabled, isFalse);
      expect(changes.last.asked, isTrue);
      final restarted = harness.restart();
      await restarted.initialize();
      expect(restarted.consent.enabled, isFalse);
      expect(restarted.consent.asked, isTrue);
      expect(harness.uploader.calls, 0);
    },
  );

  test(
    'explicit opt in sends a new error once and retains only one receipt',
    () async {
      final harness = _Harness();
      final observedReceipts = <String?>[];
      final changes = harness.controller.consentChanges.listen((_) {
        observedReceipts.add(harness.controller.lastAcceptedReportId);
      });
      addTearDown(changes.cancel);
      harness.journal.add('app', 'old error', error: true);
      await harness.controller.initialize();
      await harness.controller.setEnabled(true);
      expect(harness.uploader.calls, 0); // No history replay on opt in.
      harness.journal.add('app', 'error handshake', error: true);
      await _flush();

      expect(harness.builds, 1);
      expect(harness.uploader.calls, 1);
      final id = harness.uploader.reports.single.data['requestId'];
      expect(harness.controller.lastAcceptedReportId, id);
      expect(observedReceipts.last, id);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DiagnosticAutoSendController.lastReceiptKey), id);
      final budget = prefs.getString(DiagnosticAutoSendController.attemptsKey)!;
      expect(budget, isNot(contains('handshake')));
      expect(budget, isNot(contains('requestId')));
      expect(
        await harness.controller.handleError(harness.error('error handshake')),
        DiagnosticAutoSendResult.duplicate,
      );
      expect(harness.uploader.calls, 1);
    },
  );

  test(
    'success deduplication and cooldown survive controller rebuild',
    () async {
      final harness = _Harness();
      await harness.enable();
      expect(
        await harness.trigger('error handshake'),
        DiagnosticAutoSendResult.sent,
      );
      final restarted = harness.restart();
      await restarted.initialize();
      expect(restarted.consent.enabled, isTrue);
      expect(
        restarted.lastAcceptedReportId,
        harness.controller.lastAcceptedReportId,
      );
      expect(
        await restarted.handleError(harness.error('error handshake')),
        DiagnosticAutoSendResult.duplicate,
      );
      expect(
        await restarted.handleError(harness.error('error dns')),
        DiagnosticAutoSendResult.cooldown,
      );
      harness.clock.advance(const Duration(minutes: 15));
      expect(
        await restarted.handleError(harness.error('error dns')),
        DiagnosticAutoSendResult.sent,
      );
      expect(harness.uploader.calls, 2);
    },
  );

  test('three attempts per rolling day and a fifteen minute minimum', () async {
    final harness = _Harness();
    await harness.enable();
    for (final message in ['error handshake', 'error dns', 'error tun']) {
      expect(await harness.trigger(message), DiagnosticAutoSendResult.sent);
      harness.clock.advance(const Duration(minutes: 15));
    }
    expect(
      await harness.trigger('error quic'),
      DiagnosticAutoSendResult.dailyLimit,
    );
    harness.clock.advance(const Duration(hours: 24));
    expect(
      await harness.trigger('error handshake'),
      DiagnosticAutoSendResult.sent,
    );
    expect(harness.uploader.calls, 4);
  });

  test(
    'failed upload has no retry timer or recursion and consumes budget',
    () async {
      final harness = _Harness();
      await harness.enable();
      harness.uploader.fail = true;
      harness.uploader.onSend = () {
        harness.journal.add('dart', 'error diagnostic upload', error: true);
      };
      expect(
        await harness.trigger('error handshake'),
        DiagnosticAutoSendResult.failed,
      );
      await _flush();
      expect(harness.uploader.calls, 1);
      expect(
        await harness.trigger('error handshake'),
        DiagnosticAutoSendResult.cooldown,
      );
      for (var i = 0; i < 2; i++) {
        harness.clock.advance(const Duration(minutes: 15));
        expect(
          await harness.trigger('error handshake'),
          DiagnosticAutoSendResult.failed,
        );
      }
      harness.clock.advance(const Duration(minutes: 15));
      expect(
        await harness.trigger('error handshake'),
        DiagnosticAutoSendResult.dailyLimit,
      );
      expect(harness.uploader.calls, 3);
    },
  );

  test(
    'turning off while a report builds prevents its upload immediately',
    () async {
      final gate = Completer<DiagnosticReport>();
      final harness = _Harness(build: () => gate.future);
      await harness.enable();
      final pending = harness.trigger('error handshake');
      await _flush();
      expect(harness.builds, 1);
      final disabling = harness.controller.setEnabled(false);
      expect(harness.controller.consent.enabled, isFalse);
      gate.complete(_report(1));
      await disabling;

      expect(await pending, DiagnosticAutoSendResult.disabled);
      expect(harness.uploader.calls, 0);
      expect(
        await harness.trigger('error dns'),
        DiagnosticAutoSendResult.disabled,
      );
    },
  );

  test(
    'background errors never build and pausing during build prevents send',
    () async {
      final gate = Completer<DiagnosticReport>();
      final harness = _Harness(build: () => gate.future);
      await harness.enable();
      harness.foreground = false;
      expect(
        await harness.trigger('error handshake'),
        DiagnosticAutoSendResult.background,
      );
      expect(harness.builds, 0);
      harness.foreground = true;
      final pending = harness.trigger('error handshake');
      await _flush();
      harness.foreground = false;
      gate.complete(_report(1));
      expect(await pending, DiagnosticAutoSendResult.disabled);
      expect(harness.uploader.calls, 0);
    },
  );

  test(
    'one in flight, and disposal prevents a pending build from sending',
    () async {
      final gate = Completer<DiagnosticReport>();
      final harness = _Harness(build: () => gate.future);
      await harness.enable();
      final pending = harness.trigger('error handshake');
      await _flush();
      expect(await harness.trigger('error dns'), DiagnosticAutoSendResult.busy);
      harness.controller.dispose();
      gate.complete(_report(1));
      expect(await pending, DiagnosticAutoSendResult.disabled);
      harness.journal.add('app', 'error quic', error: true);
      await _flush();
      expect(harness.builds, 1);
      expect(harness.uploader.calls, 0);
    },
  );

  test(
    'malformed persisted budget fails closed rather than resetting limits',
    () async {
      SharedPreferences.setMockInitialValues({
        DiagnosticAutoSendController.consentKey: jsonEncode({
          'enabled': true,
          'asked': true,
        }),
        DiagnosticAutoSendController.attemptsKey: 'invalid budget',
      });
      final harness = _Harness();
      await harness.controller.initialize();
      expect(harness.controller.consent.enabled, isFalse);
      expect(
        await harness.trigger('error handshake'),
        DiagnosticAutoSendResult.disabled,
      );
      await expectLater(harness.controller.setEnabled(true), throwsStateError);
      expect(harness.builds, 0);
      expect(harness.uploader.calls, 0);
    },
  );

  test(
    'a rejected consent write cannot opt in through the preferences cache',
    () async {
      final harness = _Harness();
      await harness.controller.initialize();
      SharedPreferencesStorePlatform.instance = _RejectConsentStore(
        await SharedPreferencesStorePlatform.instance.getAll(),
      );
      await expectLater(harness.controller.setEnabled(true), throwsStateError);
      expect(harness.controller.consent.enabled, isFalse);
      final restarted = harness.restart();
      await restarted.initialize();
      expect(restarted.consent.enabled, isFalse);
      expect(
        await restarted.handleError(harness.error('error dns')),
        DiagnosticAutoSendResult.disabled,
      );
      expect(harness.uploader.calls, 0);
    },
  );

  test(
    'non-error events and observer failures do not trigger reporting',
    () async {
      final harness = _Harness();
      await harness.enable();
      final stop = harness.journal.addErrorListener((_) {
        throw StateError('synthetic observer error');
      });
      harness.journal.add('app', 'info event');
      harness.journal.add('app', 'warning event', warning: true);
      await _flush();
      expect(harness.builds, 0);
      harness.journal.add('app', 'error handshake', error: true);
      await _flush();
      expect(harness.uploader.calls, 1);
      stop();
    },
  );
}

Future<void> _flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

DiagnosticReport _report(int number) => DiagnosticReport({
  'requestId': number.toRadixString(16).padLeft(32, '0'),
  'events': <Object>[],
});

class _Clock {
  DateTime value = DateTime.utc(2026, 10, 29);
  void advance(Duration duration) => value = value.add(duration);
}

class _Harness {
  _Harness({Future<DiagnosticReport> Function()? build}) {
    _build = build ?? () async => _report(builds);
    controller = _controller();
    addTearDown(controller.dispose);
    addTearDown(journal.dispose);
    addTearDown(uploader.dispose);
  }

  final clock = _Clock();
  final journal = DiagnosticJournal(persist: false);
  final uploader = _Uploader();
  bool foreground = true;
  int builds = 0;
  late Future<DiagnosticReport> Function() _build;
  late final DiagnosticAutoSendController controller;

  DiagnosticAutoSendController _controller() => DiagnosticAutoSendController(
    buildReport: () {
      builds++;
      return _build();
    },
    uploader: uploader,
    isForeground: () => foreground,
    journal: journal,
    now: () => clock.value,
  );

  DiagnosticAutoSendController restart() {
    controller.dispose();
    final next = _controller();
    addTearDown(next.dispose);
    return next;
  }

  Future<void> enable() async {
    await controller.initialize();
    await controller.setEnabled(true);
  }

  DiagnosticEvent error(String message) =>
      DiagnosticEvent(clock.value, 'app', 'error', message);

  Future<DiagnosticAutoSendResult> trigger(String message) =>
      controller.handleError(error(message));
}

class _Uploader extends DiagnosticUploader {
  int calls = 0;
  bool fail = false;
  void Function()? onSend;
  final reports = <DiagnosticReport>[];

  @override
  Future<String> send(DiagnosticReport report) async {
    calls++;
    reports.add(report);
    onSend?.call();
    if (fail) {
      throw const DiagnosticUploadException(
        DiagnosticUploadFailure.unavailable,
      );
    }
    return report.data['requestId']! as String;
  }
}

class _RejectConsentStore extends InMemorySharedPreferencesStore {
  _RejectConsentStore(Map<String, Object> data) : super.withData(data);

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await super.setValue(valueType, key, value);
    return key != 'flutter.${DiagnosticAutoSendController.consentKey}';
  }
}
