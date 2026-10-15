import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/servers/data/services/profile_latency_service.dart';

final _proxy = const LinkDispatcher().dispatch(
  'vless://fake-id@192.0.2.10:443?security=tls&sni=node.example.test',
);

class _FakeProcess extends LatencyOwnedProcess {
  _FakeProcess(this.server, {this.ignoreKill = false, this.forceOnly = false});
  final HttpServer server;
  final bool ignoreKill;
  final bool forceOnly;
  final _exit = Completer<int>();
  final kills = <bool>[];

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill({bool force = false}) {
    kills.add(force);
    if (!ignoreKill && (!forceOnly || force)) unawaited(finish());
    return true;
  }

  Future<void> finish() async {
    await server.close(force: true);
    if (!_exit.isCompleted) _exit.complete(0);
  }
}

class _Fixture {
  _Fixture(this.root, this.binary);
  final Directory root;
  final File binary;
  final processes = <_FakeProcess>[];
  final directories = <Directory>[];
  final configs = <Map<String, dynamic>>[];
  final requests = <Uri>[];
  int active = 0;
  int maxActive = 0;
  bool unauthenticated = false;
  bool ignoreKill = false;
  bool forceOnly = false;
  String version = 'sing-box 1.13.12-extended-2.1.2';
  String delayBody = '{"delay":123}';
  int delayStatus = 200;
  Completer<void>? delayGate;
  Completer<void>? launchGate;
  final launchStarted = Completer<void>();

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('honey-probe-test-');
    final binary = await File('${root.path}/fake-core').writeAsString('fake');
    final fixture = _Fixture(root, binary);
    addTearDown(() async {
      for (final process in fixture.processes) {
        await process.finish();
      }
      await root.delete(recursive: true);
    });
    return fixture;
  }

  IsolatedCoreLatencyService service({
    Duration startupTimeout = const Duration(milliseconds: 600),
    Duration requestTimeout = const Duration(milliseconds: 300),
    bool? windowsRouting,
  }) => IsolatedCoreLatencyService(
    resolveBinary: () async => binary.path,
    temporaryDirectory: () async => root,
    launch: (binary, configPath, directory) async {
      if (!launchStarted.isCompleted) launchStarted.complete();
      if (launchGate != null) await launchGate!.future;
      final config =
          jsonDecode(await File(configPath).readAsString())
              as Map<String, dynamic>;
      configs.add(config);
      directories.add(Directory(directory));
      final api = config['experimental']['clash_api'] as Map;
      final port = int.parse(
        (api['external_controller'] as String).split(':').last,
      );
      final secret = api['secret'];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      final process = _FakeProcess(
        server,
        ignoreKill: ignoreKill,
        forceOnly: forceOnly,
      );
      processes.add(process);
      active++;
      if (active > maxActive) maxActive = active;
      unawaited(process.exitCode.then((_) => active--));
      server.listen((request) async {
        requests.add(request.uri);
        if (!unauthenticated &&
            request.headers.value(HttpHeaders.authorizationHeader) !=
                'Bearer $secret') {
          request.response.statusCode = 401;
        } else if (request.uri.path == '/version') {
          request.response.write(jsonEncode({'version': version}));
        } else {
          if (delayGate != null) await delayGate!.future;
          request.response.statusCode = delayStatus;
          request.response.write(delayBody);
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      return process;
    },
    startupTimeout: startupTimeout,
    requestTimeout: requestTimeout,
    cleanupTimeout: const Duration(milliseconds: 50),
    windowsRouting: windowsRouting,
  );
}

Future<void> _until(bool Function() condition) async {
  final deadline = Stopwatch()..start();
  while (!condition()) {
    if (deadline.elapsed > const Duration(seconds: 3))
      fail('condition timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _untilAsync(Future<bool> Function() condition) async {
  final deadline = Stopwatch()..start();
  while (!await condition()) {
    if (deadline.elapsed > const Duration(seconds: 3)) {
      fail('condition timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Widget bindings replace HttpClient with an always-400 fake. These unit
  // tests exercise only their own localhost HTTP server and no external host.
  HttpOverrides.global = null;
  test(
    'profile HTTPS delay uses isolated authenticated core and waits for its exit',
    () async {
      final fixture = await _Fixture.create();
      // This shared lifecycle case uses the platform-neutral route. Windows
      // interface detection is exercised separately with windowsRouting: true.
      final result = await fixture.service(windowsRouting: false).measure(
        _proxy,
        cancellation: LatencyCancellation(),
      );
      expect(result, 123);
      expect(fixture.active, 0);
      expect(fixture.processes.single.kills, [false]);
      expect(await fixture.directories.single.exists(), false);
      final config = fixture.configs.single;
      expect(config['inbounds'], isEmpty);
      expect(config.containsKey('endpoints'), false);
      expect(config.containsKey('tun'), false);
      expect(config['route'], {'default_domain_resolver': 'probe-local'});
      expect(config['experimental']['clash_api']['secret'], isNotEmpty);
      final delay = fixture.requests.singleWhere(
        (uri) => uri.path.endsWith('/delay'),
      );
      expect(
        delay.queryParameters['url'],
        'https://www.gstatic.com/generate_204',
      );
      expect(delay.queryParameters['timeout'], '5000');
    },
  );

  test(
    'a foreign unauthenticated API cannot produce a successful ping',
    () async {
      final fixture = await _Fixture.create()
        ..unauthenticated = true;
      expect(
        await fixture.service().measure(
          _proxy,
          cancellation: LatencyCancellation(),
        ),
        -1,
      );
      expect(
        fixture.requests.where((uri) => uri.path.endsWith('/delay')),
        isEmpty,
      );
      expect(fixture.active, 0);
    },
  );

  test('a foreign authenticated API with wrong version is rejected', () async {
    final fixture = await _Fixture.create()
      ..version = 'foreign service';
    expect(
      await fixture
          .service(startupTimeout: const Duration(milliseconds: 100))
          .measure(_proxy, cancellation: LatencyCancellation()),
      -1,
    );
    expect(
      fixture.requests.where((uri) => uri.path.endsWith('/delay')),
      isEmpty,
    );
  });

  test(
    'Windows probe keeps physical-interface binding while another TUN is active',
    () async {
      final fixture = await _Fixture.create();
      expect(
        await fixture
            .service(windowsRouting: true)
            .measure(_proxy, cancellation: LatencyCancellation()),
        123,
      );
      final config = fixture.configs.single;
      expect(config['route'], {
        'default_domain_resolver': 'probe-local',
        'auto_detect_interface': true,
      });
      expect(config['inbounds'], isEmpty);
      expect(config['outbounds'][0]['type'], 'vless');
      final binary = Platform.environment['SINGBOX_CHECK_BINARY'];
      if (binary != null) {
        final file = await File(
          '${fixture.root.path}/windows-check.json',
        ).writeAsString(jsonEncode(config));
        final checked = await Process.run(binary, ['check', '-c', file.path]);
        expect(
          checked.exitCode,
          0,
          reason: '${checked.stdout}${checked.stderr}',
        );
      }
    },
  );

  test(
    'Android probe leaves auto-detection off and relies on its excluded UID',
    () async {
      final fixture = await _Fixture.create();
      expect(
        await fixture
            .service(windowsRouting: false)
            .measure(_proxy, cancellation: LatencyCancellation()),
        123,
      );
      expect(fixture.configs.single['route'], {
        'default_domain_resolver': 'probe-local',
      });
      expect(fixture.configs.single['inbounds'], isEmpty);
    },
  );

  for (final body in [
    '{"delay":0}',
    '{"delay":-1}',
    '{"delay":70000}',
    '{"delay":"12"}',
    'not json',
    '{"delay":123,"oversize":"${'x' * 5000}"}',
  ]) {
    test(
      'invalid/bounded delay response is unavailable: ${body.length < 40 ? body : 'oversize'}',
      () async {
        final fixture = await _Fixture.create()
          ..delayBody = body;
        expect(
          await fixture.service().measure(
            _proxy,
            cancellation: LatencyCancellation(),
          ),
          -1,
        );
        expect(fixture.active, 0);
      },
    );
  }

  test('failed protocol handshake is unavailable, not TCP latency', () async {
    final fixture = await _Fixture.create()
      ..delayStatus = 503;
    expect(
      await fixture.service().measure(
        _proxy,
        cancellation: LatencyCancellation(),
      ),
      -1,
    );
  });

  test(
    'cancelling a stalled delay closes request and retires own process',
    () async {
      final fixture = await _Fixture.create()
        ..delayGate = Completer<void>();
      final cancellation = LatencyCancellation();
      final result = fixture.service().measure(
        _proxy,
        cancellation: cancellation,
      );
      await _until(
        () => fixture.requests.any((uri) => uri.path.endsWith('/delay')),
      );
      cancellation.cancel();
      expect(await result.timeout(const Duration(seconds: 1)), -1);
      expect(fixture.active, 0);
      expect(await fixture.directories.single.exists(), false);
      fixture.delayGate!.complete();
    },
  );

  test(
    'request deadline terminates stalled probe and leaves no config',
    () async {
      final fixture = await _Fixture.create()
        ..delayGate = Completer<void>();
      expect(
        await fixture
            .service(requestTimeout: const Duration(milliseconds: 40))
            .measure(_proxy, cancellation: LatencyCancellation()),
        -1,
      );
      expect(fixture.active, 0);
      expect(await fixture.directories.single.exists(), false);
      fixture.delayGate!.complete();
    },
  );

  test(
    'termination retries force only on the originally owned handle',
    () async {
      final fixture = await _Fixture.create()
        ..forceOnly = true;
      expect(
        await fixture.service().measure(
          _proxy,
          cancellation: LatencyCancellation(),
        ),
        123,
      );
      expect(fixture.processes.single.kills, [false, true]);
      expect(fixture.active, 0);
    },
  );

  test(
    'unconfirmed cleanup retains config and blocks further native processes',
    () async {
      final fixture = await _Fixture.create()
        ..ignoreKill = true;
      final service = fixture.service();
      await service.measure(_proxy, cancellation: LatencyCancellation());
      expect(await fixture.directories.single.exists(), true);
      expect(
        await service.measure(_proxy, cancellation: LatencyCancellation()),
        -1,
      );
      expect(fixture.processes, hasLength(1));
    },
  );

  test(
    'cancellation during launch retires a late process and then deletes config',
    () async {
      final fixture = await _Fixture.create()
        ..launchGate = Completer<void>();
      final cancellation = LatencyCancellation();
      final service = fixture.service();
      final result = service.measure(_proxy, cancellation: cancellation);
      // Cancel only once the config is written and native launch is in flight.
      await fixture.launchStarted.future.timeout(const Duration(seconds: 3));
      cancellation.cancel();
      expect(await result, -1);
      fixture.launchGate!.complete();
      // Process exit precedes the asynchronous directory deletion. Observe the
      // actual cleanup completion instead of treating exit as filesystem ACK.
      await _untilAsync(
        () async =>
            fixture.processes.isNotEmpty &&
            fixture.active == 0 &&
            !await fixture.directories.single.exists(),
      );
      expect(await fixture.directories.single.exists(), false);
      expect(fixture.processes.single.kills, [false]);
      fixture.launchGate = null;
      expect(
        await service.measure(_proxy, cancellation: LatencyCancellation()),
        123,
      );
    },
  );

  test(
    'Windows native cleanup waits for stop ACK even after natural exit',
    () async {
      final calls = <MethodCall>[];
      final stopAck = Completer<bool>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeLatencyOwnedProcess.channel, (
            call,
          ) async {
            calls.add(call);
            if (call.method == 'start') return 123;
            if (call.method == 'status') return {'exited': true, 'exitCode': 7};
            if (call.method == 'stop') return stopAck.future;
            throw PlatformException(code: 'unexpected');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeLatencyOwnedProcess.channel, null),
      );
      final process = await NativeLatencyOwnedProcess.start(
        'C:/Temp/honey-latency-a/config.json',
        'C:/Temp/honey-latency-a',
      );
      expect(await process.exitCode.timeout(const Duration(seconds: 1)), 7);
      var cleaned = false;
      final cleanup = process.stop(const Duration(seconds: 1)).then((result) {
        cleaned = true;
        return result;
      });
      await _until(() => calls.any((call) => call.method == 'stop'));
      expect(cleaned, false);
      stopAck.complete(true);
      expect(await cleanup, true);
      expect(calls.first.arguments, {
        'configPath': 'C:/Temp/honey-latency-a/config.json',
        'directory': 'C:/Temp/honey-latency-a',
      });
      expect(calls.last.arguments, {'id': 123});
    },
  );

  test(
    'lost Windows status channel does not acknowledge exit or cleanup',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeLatencyOwnedProcess.channel, (
            call,
          ) async {
            if (call.method == 'start') return 456;
            if (call.method == 'status') throw PlatformException(code: 'lost');
            if (call.method == 'stop') return false;
            throw PlatformException(code: 'unexpected');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeLatencyOwnedProcess.channel, null),
      );
      final process = await NativeLatencyOwnedProcess.start(
        'config',
        'directory',
      );
      expect(await process.stop(const Duration(milliseconds: 100)), false);
      expect(
        await process.exitCode.timeout(
          const Duration(milliseconds: 20),
          onTimeout: () => -99,
        ),
        -99,
      );
    },
  );

  test(
    'all individual probes share a limit of four native processes',
    () async {
      final fixture = await _Fixture.create()
        ..delayGate = Completer<void>();
      final service = fixture.service(
        requestTimeout: const Duration(seconds: 2),
      );
      final results = List.generate(
        9,
        (_) => service.measure(_proxy, cancellation: LatencyCancellation()),
      );
      await _until(
        () =>
            fixture.requests
                .where((uri) => uri.path.endsWith('/delay'))
                .length ==
            4,
      );
      expect(fixture.processes, hasLength(4));
      fixture.delayGate!.complete();
      expect(await Future.wait(results), everyElement(123));
      expect(fixture.maxActive, 4);
      expect(fixture.active, 0);
    },
  );

  test('HY2 builds QUIC profile configuration without TCP fallback', () {
    final proxy = const LinkDispatcher().dispatch(
      'hy2://fake-password@192.0.2.10:443?sni=node.example.test',
    );
    final config =
        jsonDecode(
              IsolatedCoreLatencyService.configuration(proxy, 1234, 'nonce'),
            )
            as Map;
    expect(config['outbounds'][0]['type'], 'hysteria2');
    final binary = Platform.environment['SINGBOX_CHECK_BINARY'];
    if (binary != null) {
      final directory = Directory.systemTemp.createTempSync(
        'honey-probe-config-',
      );
      try {
        final file = File('${directory.path}/config.json')
          ..writeAsStringSync(jsonEncode(config));
        final result = Process.runSync(binary, ['check', '-c', file.path]);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      } finally {
        directory.deleteSync(recursive: true);
      }
    }
  });
}
