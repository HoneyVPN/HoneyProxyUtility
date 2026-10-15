import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/windows/windows_service_backend.dart';
import 'package:honeyproxyutility/features/connection/data/windows/windows_session.dart';
import 'package:honeyproxyutility/features/subscriptions/domain/entities/provider_geo_state.dart';

final _nonce = 'a' * 64;
final _identity = {
  'nonce': _nonce,
  'parentPid': 421,
  'parentStartTicks': '638000000000000000',
};
final _serviceSession = WindowsSession(
  nonce: _nonce,
  parentPid: 421,
  parentStartTicks: '638000000000000000',
  serviceOwned: true,
);
final _proxySession = WindowsSession(
  nonce: 'b' * 64,
  parentPid: 422,
  parentStartTicks: '638000000000000001',
);
String _ok(Object? result) =>
    jsonEncode({'version': 1, 'ok': true, 'result': result});
Matcher _failure(WindowsSessionFailure failure) => throwsA(
  isA<WindowsSessionException>().having(
    (error) => error.failure,
    'safe failure',
    failure,
  ),
);

const _maximumRequestBytes = 1024 * 1024;

// These fixtures exercise only transport serialization, not the native core's
// configuration schema. The injected callback never calls a Windows service.
Map<String, dynamic> _publicWireFixture({
  required int targetBytes,
  String? proxyIp,
  bool provider = false,
}) {
  final config = <String, dynamic>{
    'publicFixture': '',
    if (provider)
      'route': {
        'rule_set': [
          {
            'type': 'inline',
            'tag': 'pgeo-${'a' * 16}-${'b' * 16}-direct',
            'rules': [
              {
                'domain_suffix': ['example.test'],
              },
            ],
          },
        ],
      },
  };
  final emptyWireBytes = utf8
      .encode(
        jsonEncode({
          'version': 1,
          'operation': 'reserve',
          'config': config,
          'httpPort': 2081,
          if (proxyIp != null) 'proxyIp': proxyIp,
        }),
      )
      .length;
  config['publicFixture'] = 'x' * (targetBytes - emptyWireBytes);
  return config;
}

void main() {
  for (final proxyIp in [null, '192.0.2.10']) {
    test(
      'complete reserve request accepts the exact UTF-8 frame limit (proxyIp=$proxyIp)',
      () async {
        var calls = 0;
        final config = _publicWireFixture(
          targetBytes: _maximumRequestBytes,
          proxyIp: proxyIp,
        );
        final backend = ServiceWindowsSessionBackend(
          request: (raw) async {
            calls++;
            expect(utf8.encode(raw).length, _maximumRequestBytes);
            final request = jsonDecode(raw) as Map<String, dynamic>;
            expect(request['config'], config);
            expect(request['httpPort'], 2081);
            if (proxyIp == null) {
              expect(request.containsKey('proxyIp'), isFalse);
            } else {
              expect(request['proxyIp'], proxyIp);
            }
            return _ok(_identity);
          },
        );
        final session = await backend.reserve(
          config,
          tunnel: true,
          httpPort: 8080,
          proxyIp: proxyIp,
        );
        expect(session.serviceOwned, isTrue);
        expect(calls, 1);
      },
    );

    test(
      'reserve request one byte over the frame limit never invokes transport (proxyIp=$proxyIp)',
      () async {
        var calls = 0;
        final backend = ServiceWindowsSessionBackend(
          request: (_) async {
            calls++;
            return _ok(_identity);
          },
        );
        await expectLater(
          backend.reserve(
            _publicWireFixture(
              targetBytes: _maximumRequestBytes + 1,
              proxyIp: proxyIp,
            ),
            tunnel: true,
            httpPort: 2081,
            proxyIp: proxyIp,
          ),
          _failure(WindowsSessionFailure.startFailed),
        );
        expect(calls, 0);
      },
    );
  }

  test(
    'oversized provider reserve preserves its typed localizable issue',
    () async {
      var calls = 0;
      final backend = ServiceWindowsSessionBackend(
        request: (_) async {
          calls++;
          return _ok(_identity);
        },
      );
      await expectLater(
        backend.reserve(
          _publicWireFixture(
            targetBytes: _maximumRequestBytes + 1,
            provider: true,
          ),
          tunnel: true,
          httpPort: 2081,
        ),
        throwsA(
          isA<ProviderGeoException>().having(
            (error) => error.issue,
            'localizable issue',
            ProviderGeoIssue.tooLarge,
          ),
        ),
      );
      expect(calls, 0);
    },
  );

  test(
    'multibyte UTF-8 overflow is rejected despite a smaller character count',
    () async {
      var calls = 0;
      final backend = ServiceWindowsSessionBackend(
        request: (_) async {
          calls++;
          return _ok(_identity);
        },
      );
      final config = {'publicFixture': 'é' * (_maximumRequestBytes ~/ 2)};
      expect(jsonEncode(config).length, lessThan(_maximumRequestBytes));
      await expectLater(
        backend.reserve(config, tunnel: true, httpPort: 2081),
        _failure(WindowsSessionFailure.startFailed),
      );
      expect(calls, 0);
    },
  );

  test(
    'TUN commands cross the service boundary without caller-supplied identity or elevation',
    () async {
      final requests = <Map<String, dynamic>>[];
      final backend = ServiceWindowsSessionBackend(
        request: (raw) async {
          final request = jsonDecode(raw) as Map<String, dynamic>;
          requests.add(request);
          return _ok(request['operation'] == 'reserve' ? _identity : null);
        },
      );
      final session = await backend.reserve(
        {
          'inbounds': [
            {'type': 'tun'},
          ],
        },
        tunnel: true,
        httpPort: 8080,
      );
      expect(session.serviceOwned, isTrue);
      await backend.launch(session, elevated: false);
      await backend.signalStop(session);
      expect(requests.map((request) => request['operation']), [
        'reserve',
        'launch',
        'signalStop',
      ]);
      for (final request in requests) {
        expect(request.keys, isNot(contains('parentPid')));
        expect(request.keys, isNot(contains('parentStartTicks')));
        expect(request.keys, isNot(contains('elevated')));
        expect(request.keys, isNot(contains('binaryPath')));
      }
      expect(requests.last['nonce'], _nonce);
      expect(requests.first['httpPort'], 2081);
    },
  );

  test('saved proxy-only ports cannot prevent a TUN reservation', () async {
    final ports = <int>[];
    final backend = ServiceWindowsSessionBackend(
      request: (raw) async {
        ports.add((jsonDecode(raw) as Map)['httpPort'] as int);
        return _ok(_identity);
      },
    );
    for (final savedProxyPort in [-1, 0, 9090, 65536]) {
      final session = await backend.reserve(
        {},
        tunnel: true,
        httpPort: savedProxyPort,
      );
      expect(session.serviceOwned, isTrue);
    }
    expect(ports, [2081, 2081, 2081, 2081]);
  });

  test(
    'user-mode Proxy can never reserve a privileged service session',
    () async {
      var calls = 0;
      final backend = ServiceWindowsSessionBackend(
        request: (_) async {
          calls++;
          return _ok(_identity);
        },
      );
      await expectLater(
        backend.reserve({}, tunnel: false, httpPort: 8080),
        _failure(WindowsSessionFailure.recoveryRequired),
      );
      await expectLater(
        backend.signalStop(_proxySession),
        _failure(WindowsSessionFailure.recoveryRequired),
      );
      expect(calls, 0);
    },
  );

  for (final identity in [
    {..._identity, 'nonce': '../session'},
    {..._identity, 'nonce': 'a' * 63},
    {..._identity, 'parentPid': -1},
    {..._identity, 'parentPid': '421'},
    {..._identity, 'parentPid': 0x100000000},
    {..._identity, 'parentStartTicks': 'unknown'},
  ]) {
    test(
      'invalid service identity is refused: ${identity.keys.join(',')}/${identity.values.first}',
      () async {
        final backend = ServiceWindowsSessionBackend(
          request: (_) async => _ok(identity),
        );
        await expectLater(
          backend.readActive(),
          _failure(WindowsSessionFailure.recoveryRequired),
        );
      },
    );
  }

  for (final reply in [
    '<html>not a service</html>',
    jsonEncode({'version': 2, 'ok': true, 'result': null}),
    jsonEncode({'version': 1, 'ok': 'true', 'result': null}),
    jsonEncode({'version': 1, 'ok': true}),
    jsonEncode({'version': 1, 'ok': false, 'code': 'private-server-password'}),
    'x' * (1024 * 1024 + 1),
  ]) {
    test(
      'malformed or unbounded service reply cannot become connection state (${reply.length} bytes)',
      () async {
        final backend = ServiceWindowsSessionBackend(
          request: (_) async => reply,
        );
        await expectLater(
          backend.readActive(),
          _failure(WindowsSessionFailure.recoveryRequired),
        );
      },
    );
  }

  test(
    'missing snapshot is unknown and is never a cleanup acknowledgement',
    () async {
      final backend = ServiceWindowsSessionBackend(
        request: (_) async => _ok(null),
      );
      expect(await backend.snapshot(_serviceSession), isNull);
    },
  );

  test(
    'unknown phases and untyped cleanup fields cannot confirm a stop',
    () async {
      for (final result in [
        {'phase': 'running', 'cleanupConfirmed': 'true'},
        {'phase': 'surprise', 'cleanupConfirmed': true},
        {'phase': 'stopped', 'cleanupConfirmed': true, 'coreExitCode': '0'},
      ]) {
        final backend = ServiceWindowsSessionBackend(
          request: (_) async => _ok(result),
        );
        await expectLater(
          backend.snapshot(_serviceSession),
          _failure(WindowsSessionFailure.recoveryRequired),
        );
      }
    },
  );

  test(
    'controller readiness requires own service snapshot and authenticated core, without UAC',
    () async {
      final operations = <String>[];
      final backend = ServiceWindowsSessionBackend(
        request: (raw) async {
          final request = jsonDecode(raw) as Map<String, dynamic>;
          final operation = request['operation'] as String;
          operations.add(operation);
          return _ok(switch (operation) {
            'readActive' => null,
            'reserve' => _identity,
            'snapshot' => {'phase': 'running', 'cleanupConfirmed': false},
            _ => null,
          });
        },
        authenticatedReady: (_) async => true,
      );
      final controller = WindowsSessionController(backend);
      expect(
        (await controller.start({}, tunnel: true, httpPort: 8080)).serviceOwned,
        isTrue,
      );
      expect(await controller.health(), WindowsSessionHealth.running);
      expect(
        operations,
        containsAllInOrder(['readActive', 'reserve', 'launch', 'snapshot']),
      );
    },
  );

  test(
    'hybrid sends only TUN to the service and stops the backend that owns the lease',
    () async {
      final proxy = _Backend(_proxySession);
      final service = _Backend(_serviceSession);
      final backend = HybridWindowsSessionBackend(
        proxyBackend: proxy,
        serviceBackend: service,
      );
      final proxyLease = await backend.reserve(
        {},
        tunnel: false,
        httpPort: 8080,
      );
      final tunLease = await backend.reserve({}, tunnel: true, httpPort: 8080);
      await backend.launch(proxyLease, elevated: true);
      await backend.launch(tunLease, elevated: false);
      await backend.signalStop(tunLease);
      expect(proxy.events, ['reserve:false', 'launch:false']);
      expect(service.events, ['reserve:true', 'launch:true', 'stop']);
    },
  );

  test(
    'both active stores block recovery instead of picking one VPN',
    () async {
      final proxy = _Backend(_proxySession)..active = _proxySession;
      final service = _Backend(_serviceSession)..active = _serviceSession;
      await expectLater(
        HybridWindowsSessionBackend(
          proxyBackend: proxy,
          serviceBackend: service,
        ).readActive(),
        _failure(WindowsSessionFailure.recoveryRequired),
      );
    },
  );

  for (final failure in [
    WindowsSessionFailure.serviceUnavailable,
    WindowsSessionFailure.serviceAccessDenied,
  ]) {
    test(
      'installed service with uncertain state blocks a new Proxy session: ${failure.name}',
      () async {
        final service = _Backend(_serviceSession)..readFailure = failure;
        await expectLater(
          HybridWindowsSessionBackend(
            proxyBackend: _Backend(_proxySession),
            serviceBackend: service,
          ).readActive(),
          _failure(failure),
        );
      },
    );
  }

  test(
    'confirmed absence of service permits Proxy recovery, but does not invent a TUN',
    () async {
      final proxy = _Backend(_proxySession)..active = _proxySession;
      final service = _Backend(_serviceSession)
        ..readFailure = WindowsSessionFailure.serviceNotInstalled;
      expect(
        await HybridWindowsSessionBackend(
          proxyBackend: proxy,
          serviceBackend: service,
        ).readActive(),
        same(_proxySession),
      );
    },
  );
}

class _Backend implements WindowsSessionBackend {
  _Backend(this.session);
  final WindowsSession session;
  WindowsSession? active;
  WindowsSessionFailure? readFailure;
  final events = <String>[];
  @override
  Duration get monotonicTime => Duration.zero;
  @override
  Future<WindowsSession?> readActive() async {
    if (readFailure != null) throw WindowsSessionException(readFailure!);
    return active;
  }

  @override
  Future<WindowsSession> reserve(
    Map<String, dynamic> config, {
    required bool tunnel,
    required int httpPort,
    String? proxyIp,
  }) async {
    events.add('reserve:$tunnel');
    return session;
  }

  @override
  Future<void> launch(WindowsSession session, {required bool elevated}) async {
    events.add('launch:$elevated');
  }

  @override
  Future<void> signalStop(WindowsSession session) async {
    events.add('stop');
  }

  @override
  Future<bool> parentAlive(WindowsSession session) async => true;
  @override
  Future<void> abortReservation(WindowsSession session) async {}
  @override
  Future<void> release(WindowsSession session) async {}
  @override
  Future<bool> authenticatedReady(WindowsSession session) async => false;
  @override
  Future<WindowsSessionSnapshot?> snapshot(WindowsSession session) async =>
      null;
  @override
  Future<void> pause(Duration duration) async {}
}
