import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/windows/windows_session.dart';

const _nonce =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _channel = MethodChannel('ru.honeyvpn.proxy/windows_session');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late Directory installed;
  late Directory selected;
  late Directory sessions;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp(
      'honey-proxy-recovery-test-',
    );
    installed = await Directory('${fixture.path}/installed').create();
    await File(
      '${installed.path}/windows_vpn_supervisor.ps1',
    ).writeAsString('');
    sessions = await Directory('${fixture.path}/windows-vpn-sessions').create();
    selected = await Directory('${sessions.path}/$_nonce').create();
    await File(
      '${sessions.path}/active.json',
    ).writeAsString(jsonEncode({'version': 1, 'nonce': _nonce}));
    await File('${selected.path}/request.json').writeAsString(
      jsonEncode({
        'version': 1,
        'nonce': _nonce,
        'parentPid': 123,
        'parentStartTicks': '638000000000000000',
      }),
    );
    await File('${selected.path}/state.json').writeAsString(
      jsonEncode({
        'version': 1,
        'nonce': _nonce,
        'phase': 'running',
        'cleanupConfirmed': false,
      }),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'isPlainPath') return true;
          throw MissingPluginException();
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await fixture.delete(recursive: true);
  });

  FileWindowsSessionBackend backend(
    Future<ProcessResult> Function(String, List<String>) runner,
  ) => FileWindowsSessionBackend(
    supportDirectory: () async => fixture,
    installedDirectory: () => installed,
    processRunner: runner,
  );

  test(
    'legacy orphan signals its captured nonce without inventing cleanup',
    () async {
      var processes = 0;
      final source = backend((_, _) async {
        processes++;
        throw StateError(
          'No process may run without a durable recovery journal',
        );
      });
      final session = (await source.readActive())!;
      await source.signalStop(session);
      expect(processes, 0);
      expect(await File('${selected.path}/stop').readAsString(), _nonce);
      expect((await source.snapshot(session))!.stopped, isFalse);
      expect(await File('${sessions.path}/active.json').exists(), isTrue);
    },
  );

  test(
    'native recovery receives only the fixed installed script and captured request',
    () async {
      await File('${selected.path}/proxy-recovery.json').writeAsString('{}');
      final commands = <List<String>>[];
      final source = backend((executable, args) async {
        expect(executable, 'powershell.exe');
        commands.add(args);
        return ProcessResult(0, 0, '', '');
      });
      final session = (await source.readActive())!;
      await source.signalStop(session);
      expect(commands, hasLength(1));
      final arguments = commands.single;
      expect(arguments.take(5), [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
      ]);
      final bytes = base64Decode(arguments.last);
      final body = String.fromCharCodes([
        for (var i = 0; i < bytes.length; i += 2) bytes[i] | bytes[i + 1] << 8,
      ]);
      expect(
        body,
        "& '${installed.path}/windows_vpn_supervisor.ps1' "
        "-Request '${selected.path}/request.json' -RecoverProxy",
      );
      // A successful helper exit is deliberately not sufficient to release a lease.
      expect((await source.snapshot(session))!.stopped, isFalse);
      expect(await File('${sessions.path}/active.json').exists(), isTrue);
    },
  );

  test(
    'failed native recovery retains the selected journal and stop token',
    () async {
      await File('${selected.path}/proxy-recovery.json').writeAsString('{}');
      final source = backend(
        (_, _) async => ProcessResult(0, 2, '', 'private failure'),
      );
      final session = (await source.readActive())!;
      await expectLater(
        source.signalStop(session),
        throwsA(
          isA<WindowsSessionException>().having(
            (e) => e.failure,
            'failure',
            WindowsSessionFailure.recoveryRequired,
          ),
        ),
      );
      expect((await source.snapshot(session))!.stopped, isFalse);
      expect(
        await File('${selected.path}/proxy-recovery.json').readAsString(),
        '{}',
      );
      expect(await File('${selected.path}/stop').readAsString(), _nonce);
      expect(await File('${sessions.path}/active.json').exists(), isTrue);
    },
  );
}
