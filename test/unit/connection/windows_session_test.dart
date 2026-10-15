import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/windows/windows_session.dart';

const _session = WindowsSession(
  nonce: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  parentPid: 123,
  parentStartTicks: '638000000000000000',
);

class _Backend implements WindowsSessionBackend {
  Duration elapsed = Duration.zero;
  @override
  Duration get monotonicTime => elapsed;
  WindowsSession? active;
  WindowsSessionSnapshot? state;
  bool parent = false;
  bool authorized = true;
  bool confirmStop = true;
  bool launchDeferred = false;
  bool launchRejected = false;
  WindowsSessionFailure launchFailure = WindowsSessionFailure.startFailed;
  bool corrupt = false;
  bool snapshotUnavailable = false;
  int stopSignals = 0;
  int released = 0;
  int childStarts = 0;
  Completer<void>? pauseGate;
  Completer<void>? launchGate;
  Completer<void>? reserveGate;

  @override
  Future<WindowsSession?> readActive() async {
    if (corrupt)
      throw const WindowsSessionException(
        WindowsSessionFailure.recoveryRequired,
      );
    return active;
  }

  @override
  Future<bool> parentAlive(WindowsSession session) async => parent;
  @override
  Future<WindowsSession> reserve(
    Map<String, dynamic> config, {
    required bool tunnel,
    required int httpPort,
    String? proxyIp,
  }) async {
    if (active != null)
      throw const WindowsSessionException(WindowsSessionFailure.busy);
    active = _session;
    state = const WindowsSessionSnapshot('launching');
    if (reserveGate != null) await reserveGate!.future;
    return _session;
  }

  @override
  Future<void> launch(WindowsSession session, {required bool elevated}) async {
    if (launchDeferred) await launchGate!.future;
    if (launchRejected) {
      state = const WindowsSessionSnapshot('failed', cleanupConfirmed: true);
      throw WindowsSessionException(launchFailure);
    }
    if (stopSignals > 0) {
      state = const WindowsSessionSnapshot('stopped', cleanupConfirmed: true);
      return;
    }
    childStarts++;
    state = const WindowsSessionSnapshot('running');
  }

  @override
  Future<WindowsSessionSnapshot?> snapshot(WindowsSession session) async {
    if (snapshotUnavailable) throw StateError('temporary IO failure');
    return state;
  }

  @override
  Future<void> abortReservation(WindowsSession session) async {
    state = const WindowsSessionSnapshot('stopped', cleanupConfirmed: true);
  }

  @override
  Future<bool> authenticatedReady(WindowsSession session) async => authorized;
  @override
  Future<void> signalStop(WindowsSession session) async {
    stopSignals++;
    if (confirmStop && !launchDeferred)
      state = const WindowsSessionSnapshot('stopped', cleanupConfirmed: true);
  }

  @override
  Future<void> release(WindowsSession session) async {
    expect(
      state?.stopped,
      isTrue,
      reason: 'Credential removal requires cleanup acknowledgement',
    );
    released++;
    active = null;
  }

  @override
  Future<void> pause(Duration duration) async {
    if (pauseGate != null) await pauseGate!.future;
    elapsed += duration;
    await Future<void>.delayed(Duration.zero);
  }
}

WindowsSessionController _controller(_Backend backend) =>
    WindowsSessionController(
      backend,
      startTimeout: const Duration(milliseconds: 5),
      stopTimeout: const Duration(milliseconds: 5),
      pollInterval: const Duration(milliseconds: 1),
    );

Matcher _failure(WindowsSessionFailure failure) =>
    isA<WindowsSessionException>().having((e) => e.failure, 'failure', failure);

void main() {
  test(
    'safe administrator-account policy failure is preserved after cleanup',
    () async {
      final backend = _Backend()
        ..launchRejected = true
        ..launchFailure = WindowsSessionFailure.proxyAccountMismatch;
      final controller = _controller(backend);
      await expectLater(
        controller.start({}, tunnel: false, httpPort: 8080),
        throwsA(_failure(WindowsSessionFailure.proxyAccountMismatch)),
      );
      expect(controller.owned, isNull);
      expect(backend.released, 1);
      expect(backend.childStarts, 0);
    },
  );

  test(
    'safe diagnostic output contains only selected codes and numeric timing',
    () {
      const state = WindowsSessionSnapshot(
        'failed',
        cleanupConfirmed: true,
        reasonCode: 'core-exited',
        coreExitCode: 5,
        connectElapsedMs: 320,
      );
      expect(state.safeDiagnosticReport(), {
        'version': 1,
        'phase': 'failed',
        'cleanupConfirmed': true,
        'reasonCode': 'core-exited',
        'coreExitCode': 5,
        'connectElapsedMs': 320,
      });
      const untrusted = WindowsSessionSnapshot(
        'failed',
        reasonCode: 'vless://credential@private-node',
        connectElapsedMs: -1,
      );
      expect(
        untrusted.safeDiagnosticReport().containsKey('reasonCode'),
        isFalse,
      );
      expect(
        untrusted.safeDiagnosticReport().containsKey('connectElapsedMs'),
        isFalse,
      );
      expect(untrusted.safeDiagnosticReport().containsKey('nonce'), isFalse);
    },
  );

  test(
    'crash before any launch safely releases a prepared dead-parent lease',
    () async {
      final backend = _Backend()
        ..active = _session
        ..state = const WindowsSessionSnapshot('prepared');
      await _controller(backend).recover();
      expect(backend.childStarts, 0);
      expect(backend.stopSignals, 0);
      expect(backend.released, 1);
    },
  );

  test(
    'live-parent cleanup snapshot cannot release an in-flight other-window lease',
    () async {
      final backend = _Backend()
        ..active = _session
        ..parent = true
        ..state = const WindowsSessionSnapshot(
          'stopped',
          cleanupConfirmed: true,
        );
      await expectLater(
        _controller(backend).recover(),
        throwsA(_failure(WindowsSessionFailure.busy)),
      );
      expect(backend.released, 0);
    },
  );

  test(
    'cancel during reservation never launches UAC or replaces another owner',
    () async {
      final backend = _Backend()..reserveGate = Completer<void>();
      final controller = _controller(backend);
      final start = controller.start({}, tunnel: true, httpPort: 8080);
      final expected = expectLater(
        start,
        throwsA(_failure(WindowsSessionFailure.startFailed)),
      );
      await Future<void>.delayed(Duration.zero);
      final stop = controller.stop();
      await expectLater(
        controller.start({}, tunnel: false, httpPort: 8080),
        throwsA(_failure(WindowsSessionFailure.busy)),
      );
      backend.reserveGate!.complete();
      await stop;
      await expected;
      expect(backend.childStarts, 0);
      expect(backend.released, 1);
      expect(controller.owned, isNull);
    },
  );

  test(
    'concurrent stop requests share the same acknowledgement and release',
    () async {
      final backend = _Backend();
      final controller = _controller(backend);
      await controller.start({}, tunnel: true, httpPort: 8080);
      await Future.wait([controller.stop(), controller.stop()]);
      expect(backend.released, 1);
      expect(controller.owned, isNull);
    },
  );

  test(
    'slow IO consumes the monotonic deadline instead of extending every poll',
    () async {
      final backend = _Backend()..authorized = false;
      final controller = _controller(backend);
      await expectLater(
        controller.start({}, tunnel: true, httpPort: 8080),
        throwsA(_failure(WindowsSessionFailure.startFailed)),
      );
      expect(backend.elapsed, const Duration(milliseconds: 5));
    },
  );

  test('foreign 9090 response cannot authenticate a new session', () async {
    final backend = _Backend()..authorized = false;
    final controller = _controller(backend);
    await expectLater(
      controller.start({}, tunnel: true, httpPort: 8080),
      throwsA(_failure(WindowsSessionFailure.startFailed)),
    );
    expect(backend.stopSignals, 1);
    expect(backend.released, 1);
    expect(controller.owned, isNull);
  });

  test('only own authenticated running state confirms startup', () async {
    final backend = _Backend();
    final controller = _controller(backend);
    expect(
      await controller.start({}, tunnel: false, httpPort: 8080),
      same(_session),
    );
    expect(await controller.running(), isTrue);
    backend.authorized = false;
    expect(await controller.running(), isFalse);
    await controller.stop();
  });

  test(
    'transient control API failure cannot declare the owned core stopped',
    () async {
      final backend = _Backend();
      final controller = _controller(backend);
      await controller.start({}, tunnel: false, httpPort: 8080);
      backend.authorized = false;
      expect(await controller.health(), WindowsSessionHealth.unavailable);
      expect(controller.owned, same(_session));
      expect(backend.stopSignals, 0);
      backend.authorized = true;
      expect(await controller.health(), WindowsSessionHealth.running);
      await controller.stop();
      expect(backend.released, 1);
    },
  );

  test(
    'missing snapshot and slow IO retain ownership until stop acknowledgement',
    () async {
      final backend = _Backend();
      final controller = _controller(backend);
      await controller.start({}, tunnel: false, httpPort: 8080);
      backend.snapshotUnavailable = true;
      expect(await controller.health(), WindowsSessionHealth.unavailable);
      backend.snapshotUnavailable = false;
      backend.state = null;
      expect(await controller.health(), WindowsSessionHealth.unavailable);
      backend.state = const WindowsSessionSnapshot(
        'failed',
        cleanupConfirmed: false,
      );
      expect(await controller.health(), WindowsSessionHealth.unavailable);
      backend.state = const WindowsSessionSnapshot(
        'failed',
        cleanupConfirmed: true,
      );
      expect(await controller.health(), WindowsSessionHealth.stopped);
      expect(controller.owned, same(_session));
      await controller.stop();
      expect(backend.released, 1);
    },
  );

  test(
    'dead-parent previous session is stopped before any new reservation',
    () async {
      final backend = _Backend()
        ..active = _session
        ..state = const WindowsSessionSnapshot('running');
      final controller = _controller(backend);
      await controller.recover();
      expect(backend.stopSignals, 1);
      expect(backend.released, 1);
      expect(backend.childStarts, 0);
    },
  );

  test('another live app window is never stopped or adopted', () async {
    final backend = _Backend()
      ..active = _session
      ..parent = true
      ..state = const WindowsSessionSnapshot('running');
    await expectLater(
      _controller(backend).recover(),
      throwsA(_failure(WindowsSessionFailure.busy)),
    );
    expect(backend.stopSignals, 0);
    expect(backend.released, 0);
    expect(backend.childStarts, 0);
  });

  test('corrupt journal fails closed without signaling any process', () async {
    final backend = _Backend()..corrupt = true;
    await expectLater(
      _controller(backend).start({}, tunnel: true, httpPort: 8080),
      throwsA(_failure(WindowsSessionFailure.recoveryRequired)),
    );
    expect(backend.stopSignals, 0);
    expect(backend.childStarts, 0);
  });

  test(
    'unconfirmed cleanup blocks recovery and retains credentials/session evidence',
    () async {
      final backend = _Backend()
        ..active = _session
        ..confirmStop = false
        ..state = const WindowsSessionSnapshot(
          'failed',
          cleanupConfirmed: false,
        );
      await expectLater(
        _controller(backend).recover(),
        throwsA(_failure(WindowsSessionFailure.recoveryRequired)),
      );
      expect(backend.released, 0);
      expect(backend.active, same(_session));
    },
  );

  test(
    'stop timeout retains ownership and can be retried after actual acknowledgement',
    () async {
      final backend = _Backend();
      final controller = _controller(backend);
      await controller.start({}, tunnel: true, httpPort: 8080);
      backend.confirmStop = false;
      await expectLater(
        controller.stop(),
        throwsA(_failure(WindowsSessionFailure.stopUnconfirmed)),
      );
      expect(controller.owned, same(_session));
      expect(backend.released, 0);
      backend.confirmStop = true;
      await controller.stop();
      expect(controller.owned, isNull);
      expect(backend.released, 1);
    },
  );

  test(
    'cleanup-confirmed failed launch releases safely and never reports running',
    () async {
      final backend = _Backend()..launchRejected = true;
      final controller = _controller(backend);
      await expectLater(
        controller.start({}, tunnel: true, httpPort: 8080),
        throwsA(_failure(WindowsSessionFailure.startFailed)),
      );
      expect(backend.childStarts, 0);
      expect(backend.released, 1);
    },
  );

  test(
    'cancellation during pending UAC leaves a nonce stop token for late approval',
    () async {
      final backend = _Backend()
        ..launchDeferred = true
        ..launchGate = Completer<void>()
        ..pauseGate = Completer<void>();
      final controller = _controller(backend);
      final start = controller.start({}, tunnel: true, httpPort: 8080);
      final startExpectation = expectLater(
        start,
        throwsA(_failure(WindowsSessionFailure.startFailed)),
      );
      await Future<void>.delayed(Duration.zero);
      final stop = controller.stop();
      await Future<void>.delayed(Duration.zero);
      expect(backend.stopSignals, 1);
      backend.launchGate!.complete();
      backend.pauseGate!.complete();
      await stop;
      await startExpectation;
      expect(backend.childStarts, 0);
      expect(controller.owned, isNull);
    },
  );

  test(
    'safe failures are localized and expose no core config or log output',
    () {
      for (final failure in WindowsSessionFailure.values) {
        final exception = WindowsSessionException(failure);
        expect(
          WindowsSessionException.messageFor(exception.code, 'ru'),
          isNotNull,
        );
        expect(
          WindowsSessionException.messageFor(exception.code, 'en'),
          isNotNull,
        );
        expect(exception.toString(), 'windowsSession:${failure.name}');
      }
      expect(
        WindowsSessionException.messageFor('foreign raw message', 'ru'),
        isNull,
      );
    },
  );
}
