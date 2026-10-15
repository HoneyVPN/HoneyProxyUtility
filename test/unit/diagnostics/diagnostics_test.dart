import 'dart:async';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_connection_details.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_application_error.dart';
import 'dart:convert';
import 'dart:io';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_core_versions.dart';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_journal.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_redactor.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_report.dart';
import 'package:honeyproxyutility/features/diagnostics/data/diagnostic_upload.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/subscriptions/data/models/subscription_model.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscriptions_notifier.dart';

class Adapter implements HttpClientAdapter {
  Adapter(this.body, {this.status = 201, this.gate});
  final String body;
  final int status;
  final Completer<void>? gate;
  RequestOptions? request;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    request = options;
    if (gate != null) await gate!.future;
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class StreamAdapter implements HttpClientAdapter {
  StreamAdapter(this.stream);
  final Stream<Uint8List> stream;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? request,
    Future<void>? cancel,
  ) async => ResponseBody(stream, 201);
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('emoji truncation and malformed UTF16 keep support JSON valid', () {
    final shortened = const DiagnosticRedactor().text(
      'a' + ('😀' * 1000),
      limit: 1000,
    );
    expect(shortened.length, lessThanOrEqualTo(1000));
    expect(shortened.runes.any((r) => r >= 0xD800 && r <= 0xDFFF), false);
    expect(
      const DiagnosticRedactor().text(
        String.fromCharCodes([0xD800, 65, 0xDFFF]),
      ),
      '�A�',
    );
  });
  test(
    'Windows clipboard CRLF and lone CR normalize to valid support newlines',
    () => expect(
      const DiagnosticRedactor().text('first\r\nsecond\rthird'),
      'first\nsecond\nthird',
    ),
  );
  test(
    'raw-link short passwords and active deleted profile are redacted',
    () async {
      final journal = DiagnosticJournal(persist: false)
        ..add('dart', 'tinyshortpass');
      final profile = ServerProfileModel(
        id: 1,
        protocol: 'trojan',
        name: 'Private',
        host: 'private.example',
        port: 443,
        subscriptionId: 'sub',
        addedAt: DateTime(2026),
        configJson: jsonEncode({
          'rawLink': 'trojan://tinyshortpass@private.example:443?security=tls',
        }),
      );
      final package = PackageInfo(
        appName: 'Honey',
        packageName: 'ru.honeyvpn.proxy',
        version: '1.2.0',
        buildNumber: '2128',
      );
      final result =
          await DiagnosticReportBuilder(
            journal: journal,
            native: () async => {
              'availability': 'not-supported',
              'state': 'unknown',
              'apiLevel': 0,
              'events': <Object>[],
            },
          ).build(
            package: package,
            settings: const AppSettings(),
            connection: NexConnectionState(
              status: ConnectionStatus.connected,
              activeServer: profile,
            ),
            subscriptions: const SubscriptionsState(),
            profiles: [],
            description: 'tinyshortpass',
          );
      expect(utf8.decode(result.bytes), isNot(contains('tinyshortpass')));
      expect(
        result.data['coverage'],
        containsPair('redactionContextComplete', true),
      );
    },
  );
  test('connection details are strict technical enums only', () {
    ServerProfileModel profile(String raw) => ServerProfileModel(
      id: 1,
      protocol: 'vless',
      name: 'Private',
      host: 'private.example',
      port: 443,
      subscriptionId: 'sub',
      addedAt: DateTime(2026),
      configJson: jsonEncode({'rawLink': raw}),
    );
    final details = diagnosticConnectionDetails(
      profile(
        'vless://12345678-1234-1234-1234-123456789abc@private.example:443?type=xhttp&security=reality&pbk=privatekey&sid=abcd&sni=private.example#Private',
      ),
    );
    expect(details, {
      'transport': 'xhttp',
      'security': 'reality',
      'flow': 'none',
    });
    expect(jsonEncode(details), isNot(contains('private')));
    expect(
      diagnosticConnectionDetails(
        profile(
          'vless://12345678-1234-1234-1234-123456789abc@private.example:443?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=privatekey&sid=abcd',
        ),
      )['flow'],
      'xtls-rprx-vision',
    );
    expect(
      diagnosticConnectionDetails(profile('not a link'))['transport'],
      'unknown',
    );
  });
  test('persisted parser cause never retains an old short credential', () {
    final result = diagnosticApplicationError(
      'Connection failed',
      source: 'ConnectionNotifier',
      error: FormatException('bad credential tiny alice tls handshake failed'),
      stack: StackTrace.fromString(
        '#0 ConnectionNotifier.connect (package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart:391:12)\n#1 tiny (/Users/alice/private/tiny.dart:1:2)',
      ),
    );
    expect(result, contains('FormatException'));
    expect(result, contains('tls handshake failed'));
    expect(result, contains('connection_notifier:391'));
    for (final secret in ['tiny', 'alice', '/Users', 'private']) {
      expect(result, isNot(contains(secret)));
    }
  });
  const redactor = DiagnosticRedactor(
    secrets: ['tiny', 'Personal Profile', 'short-secret'],
  );
  for (final raw in [
    'vless://alice:tiny@secret.example:443?uuid=abcd',
    'hysteria2://short-secret@1.2.3.4:443',
    'password=tiny token=short-secret uuid=12345678-1234-1234-1234-123456789abc',
    '{"password":"short-secret","host":"secret.example","uuid":"tiny"}',
    'Authorization: Bearer short-secret',
    'C:\\Users\\qa-user\\private\\settings.json /home/alice/conf.json',
    '192.0.2.10 [2001:db8:1234::42] 02:00:00:00:00:01',
    'alice@example.org Personal Profile',
    '[Interface]\nPrivateKey=short-secret\n[Peer]',
    '-----BEGIN PRIVATE KEY-----\nshort-secret',
  ]) {
    test('redacts ${raw.length}-character private input', () {
      final result = redactor.text(raw);
      for (final private in [
        'tiny',
        'short-secret',
        'secret.example',
        'Personal Profile',
        'qa-user',
        'alice',
        '192.0.2.10',
        '2001:db8',
        '02:00:00',
        '12345678-1234',
      ]) {
        expect(result, isNot(contains(private)));
      }
    });
  }
  test(
    'oversized data is dropped before raw truncation',
    () =>
        expect(redactor.text('tiny' * 10000), '[oversized diagnostic omitted]'),
  );
  test('core summaries discard arbitrary short credentials and URLs', () {
    final result = DiagnosticRedactor.coreSummary(
      'ERROR tls handshake failed https://example.org/password p4ss alice short-secret',
    );
    expect(result, 'error tls handshake failed');
  });
  test(
    'owned numeric exit reason stays useful',
    () => expect(
      DiagnosticRedactor.coreSummary(
        'VPN child role=sing-box kind=EXITED exit=1 signal=0 errno=0',
      ),
      contains('exit=1'),
    ),
  );
  test(
    'restored journal, append and clear serialize without resurrecting rows',
    () async {
      SharedPreferences.setMockInitialValues({
        DiagnosticJournal.key: jsonEncode([
          {
            'time': '2026-10-14T00:00:00.000Z',
            'source': 'dart',
            'level': 'error',
            'message': 'token=old-secret',
          },
        ]),
      });
      final journal = DiagnosticJournal();
      journal.add('app', 'new event');
      await journal.initialize();
      expect(journal.events.length, 2);
      expect(journal.events.first.message, isNot(contains('old-secret')));
      await journal.flush();
      final clear = journal.clear();
      journal.add('dart', 'after clear');
      await clear;
      await journal.flush();
      final stored = jsonDecode(
        (await SharedPreferences.getInstance()).getString(
          DiagnosticJournal.key,
        )!,
      );
      expect(stored.length, 1);
      expect(stored.single['message'], 'after clear');
      journal.dispose();
    },
  );
  test('journal entry and UTF8 quota preserve newest events', () {
    final journal = DiagnosticJournal(persist: false);
    for (var i = 0; i < 400; i++) {
      journal.add('dart', 'event $i ${'Ж' * 2000}');
    }
    expect(journal.events.length, lessThanOrEqualTo(300));
    expect(
      utf8
          .encode(jsonEncode(journal.events.map((e) => e.toJson()).toList()))
          .length,
      lessThanOrEqualTo(DiagnosticJournal.maxBytes),
    );
    expect(journal.events.last.message, startsWith('event 399'));
  });
  test(
    'report uses anonymous slots and removes short config secrets',
    () async {
      final journal = DiagnosticJournal(persist: false)
        ..add('dart', 'Connection failed short-secret tiny Personal Profile');
      final package = PackageInfo(
        appName: 'Honey',
        packageName: 'ru.honeyvpn.proxy',
        version: '1.2.0',
        buildNumber: '2128',
      );
      final report =
          await DiagnosticReportBuilder(
            journal: journal,
            native: () async => {
              'availability': 'not-supported',
              'state': 'unknown',
              'apiLevel': 0,
              'events': <Object>[],
            },
          ).build(
            package: package,
            platform: 'windows',
            settings: const AppSettings(),
            connection: NexConnectionState.initial(),
            subscriptions: const SubscriptionsState(
              subs: [
                SubscriptionModel(
                  id: 987,
                  url: 'https://private.example/sub/tiny',
                  name: 'Personal Profile',
                ),
              ],
            ),
            profiles: [
              ServerProfileModel(
                id: 123,
                protocol: 'vless',
                name: 'Personal Profile',
                host: 'private.example',
                port: 443,
                subscriptionId: 'https://private.example/sub/tiny',
                addedAt: DateTime(2026),
                configJson: '{"uuid":"tiny","password":"short-secret"}',
              ),
            ],
          );
      final raw = utf8.decode(report.bytes);
      for (final private in [
        'short-secret',
        'tiny',
        'Personal Profile',
        'private.example',
        'subscriptionId',
        'configJson',
        '987',
      ]) {
        expect(raw, isNot(contains(private)));
      }
      expect((report.data['subscriptions'] as List).single['slot'], 1);
      expect(
        report.data['coverage'],
        containsPair('rawWindowsCoreOutput', false),
      );
    },
  );
  test(
    'export current client schema fixture only when explicitly requested',
    () async {
      final output = Platform.environment['HONEY_DIAGNOSTIC_SCHEMA_FIXTURE'];
      if (output == null) return;
      final file = File(output);
      expect(file.existsSync(), false);
      final journal = DiagnosticJournal(persist: false)
        ..add(
          'windows-session',
          '{"phase":"failed","reasonCode":"start-failed","coreExitCode":1}',
          error: true,
        );
      final package = PackageInfo(
        appName: 'Honey',
        packageName: 'ru.honeyvpn.proxy',
        version: '1.2.0',
        buildNumber: '2128',
      );
      final result =
          await DiagnosticReportBuilder(
            journal: journal,
            native: () async => {
              'availability': 'not-supported',
              'state': 'unknown',
              'apiLevel': 0,
              'droppedEvents': 0,
              'events': <Object>[],
            },
          ).build(
            package: package,
            platform: 'windows',
            settings: const AppSettings(),
            connection: const NexConnectionState(
              status: ConnectionStatus.error,
              errorMessage: 'windowsSession:startFailed',
            ),
            subscriptions: const SubscriptionsState(),
            profiles: [],
            description: 'a' + ('😀' * 1000) + '\r\nTest note.',
          );
      await file.writeAsBytes(result.bytes, flush: true);
    },
  );
  test('core diagnostics version table matches reviewed build lock', () {
    final lock = jsonDecode(File('core-lock.json').readAsStringSync());
    expect(
      diagnosticCoreVersions('android')['singBox'],
      lock['sing_box']['assets']['android-arm64']['version'],
    );
    expect(
      diagnosticCoreVersions('windows')['singBox'],
      lock['sing_box']['assets']['windows-amd64']['version'],
    );
    expect(
      diagnosticCoreVersions('macOS')['singBox'],
      lock['sing_box']['version'],
    );
    expect(
      diagnosticCoreVersions('android')['tun2socks'],
      lock['tun2socks']['version'],
    );
  });
  test(
    'incomplete redaction context fails closed for malformed/oversized/deep/wide configs',
    () async {
      final package = PackageInfo(
        appName: 'Honey',
        packageName: 'ru.honeyvpn.proxy',
        version: '1.2.0',
        buildNumber: '2128',
      );
      for (final config in [
        'not json',
        'x' * 65537,
        jsonEncode({'nested': List.filled(129, 'tiny')}),
        '{"nested":' * 10 + '"tiny"' + '}' * 10,
      ]) {
        final journal = DiagnosticJournal(persist: false)
          ..add('dart', 'tiny unknownshortsecret');
        final profile = ServerProfileModel(
          id: 1,
          protocol: 'vless',
          name: 'Profile',
          host: 'example.org',
          port: 443,
          subscriptionId: 'sub',
          addedAt: DateTime(2026),
          configJson: config,
        );
        final result =
            await DiagnosticReportBuilder(
              journal: journal,
              native: () async => {
                'availability': 'not-supported',
                'state': 'unknown',
                'apiLevel': 0,
                'events': <Object>[],
              },
            ).build(
              package: package,
              settings: const AppSettings(),
              connection: NexConnectionState.initial(),
              subscriptions: const SubscriptionsState(),
              profiles: [profile],
              description: 'unknownshortsecret',
            );
        expect(
          result.data['coverage'],
          containsPair('redactionContextComplete', false),
        );
        expect(
          utf8.decode(result.bytes),
          isNot(contains('unknownshortsecret')),
        );
      }
    },
  );
  test(
    'upload is HTTPS fixed endpoint JSON, no redirects and successful receipt only',
    () async {
      final adapter = Adapter('{"accepted":true,"reportId":"${'a' * 32}"}');
      final uploader = DiagnosticUploader(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final report = DiagnosticReport({'schema': 1, 'requestId': 'a' * 32});
      expect(await uploader.send(report), 'a' * 32);
      expect(adapter.request!.uri, DiagnosticUploader.endpoint);
      expect(adapter.request!.uri.scheme, 'https');
      expect(adapter.request!.followRedirects, false);
      expect(
        adapter.request!.data,
        jsonEncode({'schema': 1, 'requestId': 'a' * 32}),
      );
      uploader.dispose();
    },
  );
  test(
    'upload rejects redirects, oversized response and fake receipt',
    () async {
      for (final adapter in [
        Adapter('{}', status: 302),
        Adapter('x' * 1025),
        Adapter('{"accepted":false,"reportId":"${'a' * 32}"}'),
      ]) {
        final uploader = DiagnosticUploader(
          dio: Dio()..httpClientAdapter = adapter,
        );
        await expectLater(
          uploader.send(DiagnosticReport({})),
          throwsA(isA<DiagnosticUploadException>()),
        );
        uploader.dispose();
      }
    },
  );
  test('stalled receipt stream is cancelled within total deadline', () async {
    var cancelled = false;
    final stream = StreamController<Uint8List>(
      onCancel: () {
        cancelled = true;
      },
    );
    final uploader = DiagnosticUploader(
      dio: Dio()..httpClientAdapter = StreamAdapter(stream.stream),
      totalTimeout: const Duration(milliseconds: 40),
    );
    await expectLater(
      uploader.send(DiagnosticReport({'requestId': 'a' * 32})),
      throwsA(
        isA<DiagnosticUploadException>().having(
          (e) => e.failure,
          'failure',
          DiagnosticUploadFailure.timeout,
        ),
      ),
    );
    expect(cancelled, true);
    await stream.close();
    uploader.dispose();
  });
  test(
    'never-finishing response cancellation releases uploader within cleanup bound',
    () async {
      final never = Completer<void>();
      final stream = StreamController<Uint8List>(onCancel: () => never.future);
      final dio = Dio()..httpClientAdapter = StreamAdapter(stream.stream);
      final uploader = DiagnosticUploader(
        dio: dio,
        totalTimeout: const Duration(milliseconds: 40),
      );
      final watch = Stopwatch()..start();
      final pending = uploader.send(DiagnosticReport({'requestId': 'a' * 32}));
      await expectLater(pending, throwsA(isA<DiagnosticUploadException>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      dio.httpClientAdapter = Adapter(
        '{"accepted":true,"reportId":"${'a' * 32}"}',
      );
      expect(
        await uploader.send(DiagnosticReport({'requestId': 'a' * 32})),
        'a' * 32,
      );
      never.complete();
      await stream.close();
      uploader.dispose();
    },
  );
  test('failed cancellation preserves the classified upload failure', () async {
    final stream = StreamController<Uint8List>(
      onCancel: () =>
          Future<void>.error(StateError('Synthetic cancellation failure')),
    );
    final uploader = DiagnosticUploader(
      dio: Dio()..httpClientAdapter = StreamAdapter(stream.stream),
      totalTimeout: const Duration(milliseconds: 40),
    );
    await expectLater(
      uploader.send(DiagnosticReport({'requestId': 'a' * 32})),
      throwsA(
        isA<DiagnosticUploadException>().having(
          (e) => e.failure,
          'failure',
          DiagnosticUploadFailure.timeout,
        ),
      ),
    );
    await stream.close();
    uploader.dispose();
  });
  test('receipt from a different request is rejected', () async {
    final uploader = DiagnosticUploader(
      dio: Dio()
        ..httpClientAdapter = Adapter(
          '{"accepted":true,"reportId":"${'b' * 32}"}',
        ),
    );
    await expectLater(
      uploader.send(DiagnosticReport({'requestId': 'a' * 32})),
      throwsA(isA<DiagnosticUploadException>()),
    );
    uploader.dispose();
  });
  test(
    'upload coalescing blocks a second click; demo never calls adapter',
    () async {
      final gate = Completer<void>();
      final adapter = Adapter(
        '{"accepted":true,"reportId":"${'b' * 32}"}',
        gate: gate,
      );
      final uploader = DiagnosticUploader(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final first = uploader.send(DiagnosticReport({'requestId': 'b' * 32}));
      await expectLater(
        uploader.send(DiagnosticReport({})),
        throwsA(isA<DiagnosticUploadException>()),
      );
      gate.complete();
      await first;
      uploader.dispose();
      final untouched = Adapter('{}');
      final demo = DiagnosticUploader(
        dio: Dio()..httpClientAdapter = untouched,
        demo: true,
      );
      expect(await demo.send(DiagnosticReport({})), 'DEMO-LOCAL');
      expect(untouched.request, isNull);
      demo.dispose();
    },
  );
}
