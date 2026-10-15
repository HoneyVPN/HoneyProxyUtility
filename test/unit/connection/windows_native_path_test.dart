import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/windows/windows_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ru.honeyvpn.proxy/windows_session');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  FileWindowsSessionBackend backend() => FileWindowsSessionBackend(
    supportDirectory: () async => Directory('C:\\Test User\\HoneyVPN'),
  );
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });
  for (final result in [false, null]) {
    test(
      'native path inspection $result fails closed before any IO/process',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return result;
        });
        await expectLater(
          backend().readActive(),
          throwsA(isA<WindowsSessionException>()),
        );
        expect(calls, hasLength(1));
        expect(calls.single.method, 'isPlainPath');
        expect(calls.single.arguments, endsWith('windows-vpn-sessions'));
      },
    );
  }
  test('missing native channel fails closed before session IO', () async {
    await expectLater(
      backend().readActive(),
      throwsA(isA<WindowsSessionException>()),
    );
  });

  test('file backend cannot bypass the installed service for TUN', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return false;
    });
    await expectLater(
      backend().confirmLaunchPrivileges(tunnel: true),
      throwsA(
        isA<WindowsSessionException>().having(
          (e) => e.failure,
          'failure',
          WindowsSessionFailure.serviceUnavailable,
        ),
      ),
    );
    expect(calls, isEmpty);
    await expectLater(
      backend().reserve({}, tunnel: true, httpPort: 2081),
      throwsA(isA<WindowsSessionException>().having(
        (e) => e.failure, 'failure', WindowsSessionFailure.serviceUnavailable,
      )),
    );
    expect(calls, isEmpty);
  });

  test('proxy cannot edit an account other than the desktop owner', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'isElevated',
    );
    await expectLater(
      backend().confirmLaunchPrivileges(tunnel: false),
      throwsA(
        isA<WindowsSessionException>().having(
          (e) => e.failure,
          'failure',
          WindowsSessionFailure.proxyAccountMismatch,
        ),
      ),
    );
  });

  test(
    'same-account proxy works without checking administrator rights',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return true;
      });
      await backend().confirmLaunchPrivileges(tunnel: false);
      expect(calls, ['ownsInteractiveProxySettings']);
    },
  );
}
