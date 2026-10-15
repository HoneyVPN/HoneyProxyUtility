import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../../diagnostics/data/diagnostic_journal.dart';

enum WindowsSessionFailure {
  busy,
  recoveryRequired,
  startFailed,
  stopUnconfirmed,
  connectionLost,
  proxyAccountMismatch,
  serviceNotInstalled,
  serviceUnavailable,
  serviceAccessDenied,
}

enum WindowsSessionHealth { running, stopped, unavailable }

class WindowsSessionException implements Exception {
  const WindowsSessionException(this.failure);
  final WindowsSessionFailure failure;
  String get code => 'windowsSession:${failure.name}';
  @override
  String toString() => code;

  static String? messageFor(String code, String locale) {
    final failure = WindowsSessionFailure.values
        .where((f) => code == 'windowsSession:${f.name}')
        .firstOrNull;
    if (failure == null) return null;
    final ru = locale == 'ru';
    return switch (failure) {
      WindowsSessionFailure.busy =>
        ru
            ? 'VPN уже используется другим окном приложения. Отключите его в том окне.'
            : 'Another app window owns the VPN. Disconnect it in that window.',
      WindowsSessionFailure.recoveryRequired =>
        ru
            ? 'Не удалось подтвердить очистку предыдущего VPN. Если ошибка остаётся после перезагрузки Windows, потребуется восстановление с помощью поддержки.'
            : 'Cleanup of the previous VPN could not be confirmed. If the error persists after restarting Windows, contact support for recovery.',
      WindowsSessionFailure.startFailed =>
        ru
            ? 'VPN не запустился. Попробуйте подключиться снова или выберите другой сервер.'
            : 'VPN did not start. Retry connecting or choose another server.',
      WindowsSessionFailure.stopUnconfirmed =>
        ru
            ? 'Остановка VPN не подтверждена. Попробуйте отключить ещё раз; при повторной ошибке перезагрузите Windows.'
            : 'VPN stop could not be confirmed. Retry disconnecting; if it fails again, restart Windows.',
      WindowsSessionFailure.connectionLost =>
        ru
            ? 'VPN завершил работу. Подключитесь снова или выберите другой сервер.'
            : 'The VPN process stopped. Reconnect or choose another server.',
      WindowsSessionFailure.proxyAccountMismatch =>
        ru
            ? 'Для режима «Прокси» приложение должно работать в том же аккаунте Windows, что и браузер. Запустите его в своём аккаунте или используйте «Туннель».'
            : 'Proxy mode requires the same Windows account as your browser. Run the app in your account or use Tunnel.',
      WindowsSessionFailure.serviceNotInstalled =>
        ru
            ? 'Служба VPN не установлена. Установите HoneyProxyUtility через установщик Windows.'
            : 'The VPN service is not installed. Install HoneyProxyUtility using the Windows installer.',
      WindowsSessionFailure.serviceUnavailable =>
        ru
            ? 'Служба VPN недоступна. Перезапустите приложение; при повторной ошибке восстановите установку HoneyProxyUtility.'
            : 'The VPN service is unavailable. Restart the app; if the error persists, repair the HoneyProxyUtility installation.',
      WindowsSessionFailure.serviceAccessDenied =>
        ru
            ? 'Нет доступа к службе VPN. Запустите приложение в аккаунте Windows, для которого оно установлено.'
            : 'Access to the VPN service was denied. Run the app in the Windows account used for its installation.',
    };
  }
}

class WindowsSession {
  const WindowsSession({
    required this.nonce,
    required this.parentPid,
    required this.parentStartTicks,
    this.serviceOwned = false,
  });
  final String nonce;
  final int parentPid;
  final String parentStartTicks;
  final bool serviceOwned;
}

class WindowsSessionSnapshot {
  const WindowsSessionSnapshot(
    this.phase, {
    this.cleanupConfirmed = false,
    this.reasonCode,
    this.coreExitCode,
    this.connectElapsedMs,
  });
  final String phase;
  final bool cleanupConfirmed;
  final String? reasonCode;
  final int? coreExitCode;
  final int? connectElapsedMs;
  bool get stopped =>
      (phase == 'stopped' || phase == 'failed') && cleanupConfirmed;

  /// Safe to share: never include the session nonce, server, profile or config.
  Map<String, dynamic> safeDiagnosticReport() => {
    'version': 1,
    'phase': phase,
    'cleanupConfirmed': cleanupConfirmed,
    if (reasonCode != null && _safeReasonCodes.contains(reasonCode))
      'reasonCode': reasonCode,
    if (coreExitCode != null) 'coreExitCode': coreExitCode,
    if (connectElapsedMs != null && connectElapsedMs! >= 0)
      'connectElapsedMs': connectElapsedMs,
  };

  static const _safeReasonCodes = {
    'none',
    'core-exited',
    'parent-exited',
    'broker-exited',
    'cancelled',
    'unsafe-path',
    'invalid-request',
    'invalid-config',
    'missing-core',
    'missing-gateway',
    'missing-interface-metric',
    'missing-proxy-settings',
    'proxy-notify-failed',
    'start-failed',
    'start-cancelled',
    'supervisor-failed',
    'proxy-settings-overridden',
    'proxy-restore-unconfirmed',
    'proxy-query-failed',
    'proxy-set-failed',
    'proxy-abi-mismatch',
    'proxy-job-failed',
    'proxy-job-unconfirmed',
    'proxy-recovery-invalid',
    'proxy-recovery-unavailable',
    'proxy-recovered',
  };
}

/// Fakeable boundary: tests never start a core, edit the registry, or use UAC.
abstract interface class WindowsSessionBackend {
  Duration get monotonicTime;
  Future<WindowsSession?> readActive();
  Future<bool> parentAlive(WindowsSession session);
  Future<WindowsSession> reserve(
    Map<String, dynamic> config, {
    required bool tunnel,
    required int httpPort,
    String? proxyIp,
  });
  Future<void> launch(WindowsSession session, {required bool elevated});
  Future<void> abortReservation(WindowsSession session);
  Future<WindowsSessionSnapshot?> snapshot(WindowsSession session);
  Future<bool> authenticatedReady(WindowsSession session);
  Future<void> signalStop(WindowsSession session);
  Future<void> release(WindowsSession session);
  Future<void> pause(Duration duration);
}

/// A recovered PID is never a kill target. Only the supervisor which retained
/// the original process handle is allowed to stop its child and restore state.
class WindowsSessionController {
  WindowsSessionController(
    this.backend, {
    this.startTimeout = const Duration(seconds: 60),
    this.stopTimeout = const Duration(seconds: 15),
    this.pollInterval = const Duration(milliseconds: 250),
  });
  final WindowsSessionBackend backend;
  final Duration startTimeout;
  final Duration stopTimeout;
  final Duration pollInterval;
  WindowsSession? _owned;
  bool _starting = false;
  bool _recovering = false;
  bool _launchStarted = false;
  Future<WindowsSession>? _reservation;
  Future<void>? _stopping;
  int _generation = 0;
  WindowsSession? get owned => _owned;
  String? _lastDiagnostic;
  Future<WindowsSessionSnapshot?> _snapshot(WindowsSession session) async {
    final snapshot = await backend.snapshot(session);
    if (snapshot != null) {
      final message = jsonEncode(snapshot.safeDiagnosticReport());
      if (message != _lastDiagnostic) {
        _lastDiagnostic = message;
        DiagnosticJournal.shared.add(
          'windows-session',
          message,
          error: snapshot.phase == 'failed',
        );
      }
    }
    return snapshot;
  }

  Future<void> recover() async {
    if (_starting || _recovering || _owned != null || _stopping != null) {
      throw const WindowsSessionException(WindowsSessionFailure.busy);
    }
    _recovering = true;
    try {
      await _bounded(
        _recover(),
        backend.monotonicTime + stopTimeout + const Duration(seconds: 15),
        WindowsSessionFailure.recoveryRequired,
      );
    } finally {
      _recovering = false;
    }
  }

  Future<void> _recover() async {
    final active = await backend.readActive();
    if (active == null) return;
    // A second window must not release a prepared/live parent's lease while
    // that parent is about to launch, or publish a new reservation into it.
    if (await backend.parentAlive(active)) {
      throw const WindowsSessionException(WindowsSessionFailure.busy);
    }
    final snapshot = await _snapshot(active);
    if (snapshot?.phase == 'prepared') {
      // Production marks 'launching' before any child/UAC invocation. Prepared
      // plus a dead original parent therefore proves no launch was attempted.
      await backend.abortReservation(active);
      await backend.release(active);
      return;
    }
    if (snapshot?.stopped == true) {
      await backend.release(active);
      return;
    }
    await backend.signalStop(active);
    await _waitStopped(active, WindowsSessionFailure.recoveryRequired);
    await backend.release(active);
  }

  Future<WindowsSession> start(
    Map<String, dynamic> config, {
    required bool tunnel,
    required int httpPort,
    String? proxyIp,
  }) {
    if (_starting || _recovering || _owned != null || _stopping != null) {
      return Future.error(
        const WindowsSessionException(WindowsSessionFailure.busy),
      );
    }
    _starting = true;
    return _start(
      config,
      tunnel: tunnel,
      httpPort: httpPort,
      proxyIp: proxyIp,
    ).whenComplete(() {
      _starting = false;
      _reservation = null;
    });
  }

  Future<WindowsSession> _start(
    Map<String, dynamic> config, {
    required bool tunnel,
    required int httpPort,
    String? proxyIp,
  }) async {
    final generation = ++_generation;
    final deadline = backend.monotonicTime + startTimeout;
    await _bounded(
      _recover(),
      deadline,
      WindowsSessionFailure.recoveryRequired,
    );
    if (generation != _generation) {
      throw const WindowsSessionException(WindowsSessionFailure.startFailed);
    }
    final reservation = backend.reserve(
      config,
      tunnel: tunnel,
      httpPort: httpPort,
      proxyIp: proxyIp,
    );
    _reservation = reservation;
    WindowsSession session;
    try {
      session = await _bounded(
        reservation,
        deadline,
        WindowsSessionFailure.startFailed,
      );
    } catch (_) {
      // Reservation can finish after a timeout. No launch has occurred, so its
      // captured nonce can be safely abandoned without publishing a new owner.
      unawaited(
        reservation
            .then((late) async {
              await backend.abortReservation(late);
              await backend.release(late);
            })
            .catchError((Object _) {}),
      );
      rethrow;
    }
    _owned = session;
    if (generation != _generation) {
      await _stopSession(session);
      throw const WindowsSessionException(WindowsSessionFailure.startFailed);
    }
    Object? launchError;
    _launchStarted = true;
    unawaited(
      backend.launch(session, elevated: tunnel).catchError((Object e) {
        launchError = e;
      }),
    );
    while (backend.monotonicTime < deadline) {
      if (generation != _generation) {
        throw const WindowsSessionException(WindowsSessionFailure.startFailed);
      }
      WindowsSessionSnapshot? state;
      bool ready = false;
      try {
        state = await _bounded(
          _snapshot(session),
          deadline,
          WindowsSessionFailure.startFailed,
        );
        if (state?.phase == 'running') {
          ready = await _bounded(
            backend.authenticatedReady(session),
            deadline,
            WindowsSessionFailure.startFailed,
          );
        }
      } on WindowsSessionException {
        break;
      }
      if (ready) {
        if (generation == _generation) return session;
        break;
      }
      if (state?.stopped == true || launchError != null) break;
      await backend.pause(pollInterval);
    }
    // This cleanup is scoped to the captured lease. It cannot stop a new owner.
    await _stopSession(session);
    final error = launchError;
    if (error is WindowsSessionException) throw error;
    throw const WindowsSessionException(WindowsSessionFailure.startFailed);
  }

  Future<void> stop() async {
    _generation++;
    final deadline = backend.monotonicTime + stopTimeout;
    var session = _owned;
    final reservation = _reservation;
    if (session == null && reservation != null) {
      try {
        session = await _bounded(
          reservation,
          deadline,
          WindowsSessionFailure.stopUnconfirmed,
        );
      } on TimeoutException {
        rethrow;
      } on WindowsSessionException {
        rethrow;
      } catch (_) {
        return;
      }
    }
    if (session != null) await _stopSession(session);
  }

  Future<void> _stopSession(WindowsSession session) {
    if (_stopping != null) return _stopping!;
    final operation = _finishStop(session);
    // Coalesce stop/dispose/cancel acknowledgements for this single lease.
    _stopping = operation.whenComplete(() {
      _stopping = null;
    });
    return _stopping!;
  }

  Future<void> _finishStop(WindowsSession session) async {
    final deadline = backend.monotonicTime + stopTimeout;
    if (!_launchStarted)
      await _bounded(
        backend.abortReservation(session),
        deadline,
        WindowsSessionFailure.stopUnconfirmed,
      );
    await _bounded(
      backend.signalStop(session),
      deadline,
      WindowsSessionFailure.stopUnconfirmed,
    );
    await _waitStopped(
      session,
      WindowsSessionFailure.stopUnconfirmed,
      deadline: deadline,
    );
    await _bounded(
      backend.release(session),
      deadline,
      WindowsSessionFailure.stopUnconfirmed,
    );
    if (identical(_owned, session)) _owned = null;
    _launchStarted = false;
  }

  Future<bool> running() async {
    return await health() == WindowsSessionHealth.running;
  }

  /// Only a supervisor acknowledgement proves that a session ended. A control
  /// API timeout, a temporarily absent state file, or slow filesystem IO cannot
  /// revoke the retained lease or change the UI to a disconnected session.
  Future<WindowsSessionHealth> health() async {
    final session = _owned;
    if (session == null) return WindowsSessionHealth.stopped;
    try {
      final state = await _snapshot(session);
      if (state?.stopped == true) return WindowsSessionHealth.stopped;
      if (state?.phase == 'running' &&
          await backend.authenticatedReady(session)) {
        return WindowsSessionHealth.running;
      }
    } catch (_) {
      // Keep the owner so a retrying stop still addresses the captured session.
    }
    return WindowsSessionHealth.unavailable;
  }

  Future<void> _waitStopped(
    WindowsSession session,
    WindowsSessionFailure failure, {
    Duration? deadline,
  }) async {
    final limit = deadline ?? backend.monotonicTime + stopTimeout;
    while (backend.monotonicTime < limit) {
      if ((await _bounded(_snapshot(session), limit, failure))?.stopped == true)
        return;
      await backend.pause(pollInterval);
    }
    throw WindowsSessionException(failure);
  }

  Future<T> _bounded<T>(
    Future<T> operation,
    Duration deadline,
    WindowsSessionFailure failure,
  ) {
    final remaining = deadline - backend.monotonicTime;
    if (remaining <= Duration.zero)
      return Future.error(WindowsSessionException(failure));
    return operation.timeout(
      remaining,
      onTimeout: () => throw WindowsSessionException(failure),
    );
  }
}

class FileWindowsSessionBackend implements WindowsSessionBackend {
  FileWindowsSessionBackend({
    Future<Directory> Function()? supportDirectory,
    Future<ProcessResult> Function(String, List<String>)? processRunner,
    Directory Function()? installedDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _processRunner = processRunner ?? Process.run,
       _installedDirectory =
           installedDirectory ??
           (() => File(Platform.resolvedExecutable).parent);
  final Future<Directory> Function() _supportDirectory;
  final Future<ProcessResult> Function(String, List<String>) _processRunner;
  final Directory Function() _installedDirectory;
  final Stopwatch _clock = Stopwatch()..start();
  final Set<String> _released = {};
  final Set<String> _reservedHere = {};
  @override
  Duration get monotonicTime => _clock.elapsed;
  Future<ProcessResult> _run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 5),
  }) => _processRunner(executable, arguments).timeout(
    timeout,
    onTimeout: () => throw const WindowsSessionException(
      WindowsSessionFailure.recoveryRequired,
    ),
  );
  Directory? _root;
  static const _native = MethodChannel('ru.honeyvpn.proxy/windows_session');
  Future<Directory> _directory() async {
    if (_root != null) {
      await _assertPlain(_root!.path);
      return _root!;
    }
    final support = await _supportDirectory();
    final root = Directory('${support.path}/windows-vpn-sessions');
    await _assertPlain(root.path);
    await root.create(recursive: true);
    await _assertPlain(root.path);
    return _root = root;
  }

  static final _noncePattern = RegExp(r'^[a-f0-9]{64}$');
  String _path(Directory root, WindowsSession session, String name) {
    if (!_noncePattern.hasMatch(session.nonce)) _invalid();
    return '${root.path}/${session.nonce}/$name';
  }

  Never _invalid() => throw const WindowsSessionException(
    WindowsSessionFailure.recoveryRequired,
  );

  Future<void> _assertPlain(String path) async {
    // GetFileAttributesW checks every existing ancestor, including junctions.
    // An in-process read removes dozens of PowerShell starts from connection
    // setup and every health poll. Missing/failed native inspection is unsafe.
    try {
      if (await _native.invokeMethod<bool>('isPlainPath', path) != true) {
        _invalid();
      }
    } catch (_) {
      _invalid();
    }
  }

  Future<Map<String, dynamic>?> _read(String path) async {
    if (!await File(path).exists()) return null;
    await _assertPlain(path);
    final file = File(path);
    if (await file.length() > 16384) _invalid();
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) _invalid();
      return value;
    } catch (_) {
      _invalid();
    }
  }

  @override
  Future<WindowsSession?> readActive() async {
    final root = await _directory();
    final pointer = await _read('${root.path}/active.json');
    if (pointer == null) return null;
    final nonce = pointer['nonce'];
    if (pointer['version'] != 1 ||
        nonce is! String ||
        !_noncePattern.hasMatch(nonce))
      _invalid();
    final session = WindowsSession(
      nonce: nonce,
      parentPid: 0,
      parentStartTicks: '',
    );
    final request = await _read(_path(root, session, 'request.json'));
    if (request == null ||
        request['nonce'] != nonce ||
        request['version'] != 1 ||
        request['parentPid'] is! int ||
        (request['parentPid'] as int) <= 0 ||
        request['parentStartTicks'] is! String ||
        !RegExp(r'^\d{15,20}$').hasMatch(request['parentStartTicks'] as String))
      _invalid();
    return WindowsSession(
      nonce: nonce,
      parentPid: request['parentPid'] as int,
      parentStartTicks: request['parentStartTicks'] as String,
    );
  }

  @override
  Future<bool> parentAlive(WindowsSession session) async {
    final result = await _run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'try {\$p=[Diagnostics.Process]::GetProcessById(${session.parentPid}); '
          '\$null=\$p.Handle; if(\$p.StartTime.ToUniversalTime().Ticks.ToString() -eq '
          "'${session.parentStartTicks}' -and -not \$p.HasExited){exit 0}} catch [ArgumentException] {exit 1} catch {exit 2}; exit 1",
    ]);
    if (result.exitCode != 0 && result.exitCode != 1) _invalid();
    return result.exitCode == 0;
  }

  @override
  Future<WindowsSession> reserve(
    Map<String, dynamic> config, {
    required bool tunnel,
    required int httpPort,
    String? proxyIp,
  }) async {
    if (tunnel) {
      throw const WindowsSessionException(
        WindowsSessionFailure.serviceUnavailable,
      );
    }
    final root = await _directory();
    final random = Random.secure();
    final nonce = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final creation = await _run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '[Diagnostics.Process]::GetProcessById($pid).StartTime.ToUniversalTime().Ticks.ToString()',
    ]);
    final ticks = creation.stdout.toString().trim();
    if (creation.exitCode != 0 || !RegExp(r'^\d{15,20}$').hasMatch(ticks))
      _invalid();
    final session = WindowsSession(
      nonce: nonce,
      parentPid: pid,
      parentStartTicks: ticks,
    );
    final directory = Directory('${root.path}/$nonce');
    await _assertPlain(directory.path);
    await directory.create();
    await _assertPlain(directory.path);
    final runtime = jsonDecode(jsonEncode(config)) as Map<String, dynamic>;
    ((runtime['experimental'] as Map)['clash_api'] as Map)['secret'] = nonce;
    await File(
      _path(root, session, 'config.json'),
    ).writeAsString(jsonEncode(runtime), flush: true);
    await File(_path(root, session, 'request.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'nonce': nonce,
        'parentPid': pid,
        'parentStartTicks': ticks,
        'tunnel': tunnel,
        'httpPort': httpPort,
        'proxyIp': proxyIp,
      }),
      flush: true,
    );
    await _writeState(session, 'prepared', false);
    final pointerPath = base64Encode(utf8.encode('${root.path}/active.json'));
    final pointer = base64Encode(
      utf8.encode(jsonEncode({'version': 1, 'nonce': nonce})),
    );
    final reserved = await _run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "\$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$pointerPath')); "
          "try{\$f=[IO.File]::Open(\$p,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None); "
          "try{\$b=[Convert]::FromBase64String('$pointer');\$f.Write(\$b,0,\$b.Length);\$f.Flush()}finally{\$f.Dispose()};exit 0}catch{exit 2}",
    ]);
    if (reserved.exitCode != 0) {
      await directory.delete(recursive: true);
      throw const WindowsSessionException(WindowsSessionFailure.busy);
    }
    _reservedHere.add(nonce);
    return session;
  }

  @override
  Future<void> launch(WindowsSession session, {required bool elevated}) async {
    final root = await _directory();
    final exeDir = _installedDirectory();
    final script = File('${exeDir.path}/windows_vpn_supervisor.ps1');
    final core = File('${exeDir.path}/sing-box.exe');
    if (!await script.exists() || !await core.exists()) {
      await _writeNotLaunched(session);
      throw const WindowsSessionException(WindowsSessionFailure.startFailed);
    }
    try {
      await confirmLaunchPrivileges(tunnel: elevated);
    } catch (_) {
      await _writeNotLaunched(session);
      rethrow;
    }
    final request = _path(root, session, 'request.json');
    // A crash before this transition is recoverable without guessing whether
    // a late elevated child exists. From this point onward stop requires ACK.
    await _writeState(session, 'launching', false);
    // Encode complete PowerShell literals, then quote its single ArgumentList
    // string. Start-Process joins arrays without escaping spaces automatically.
    final quotedScript = script.path.replaceAll("'", "''");
    final quotedRequest = request.replaceAll("'", "''");
    final command = "& '$quotedScript' -Request '$quotedRequest'";
    final encoded = base64Encode(utf16le(command));
    final result = await _run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      // Proxy supervision inherits the interactive user's token; it does not
      // request elevation or change another account's proxy settings.
      "try{\$p=Start-Process powershell.exe -WindowStyle Hidden "
          "-PassThru -ArgumentList '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded';exit 0}catch{exit 2}",
    ], timeout: const Duration(seconds: 65));
    if (result.exitCode != 0) {
      await _writeNotLaunched(session);
      throw const WindowsSessionException(WindowsSessionFailure.startFailed);
    }
  }

  /// Read-only policy boundary, independently testable without launching a
  /// process or editing either account's registry.
  Future<void> confirmLaunchPrivileges({required bool tunnel}) async {
    // File/supervisor sessions are per-user Proxy only. TUN must use the
    // installed service; there is no direct or repeatedly elevated fallback.
    if (tunnel) {
      throw const WindowsSessionException(
        WindowsSessionFailure.serviceUnavailable,
      );
    }
    if (!tunnel) {
      var ownDesktopProxy = false;
      try {
        ownDesktopProxy =
            await _native
                .invokeMethod<bool>('ownsInteractiveProxySettings')
                .timeout(const Duration(seconds: 5)) ==
            true;
      } catch (_) {}
      if (!ownDesktopProxy) {
        throw const WindowsSessionException(
          WindowsSessionFailure.proxyAccountMismatch,
        );
      }
    }
  }

  static List<int> utf16le(String text) => [
    for (final c in text.codeUnits) ...[c & 255, c >> 8],
  ];
  Future<void> _writeNotLaunched(WindowsSession session) =>
      _writeState(session, 'failed', true);

  Future<void> _writeState(
    WindowsSession session,
    String phase,
    bool cleanupConfirmed,
  ) async {
    final root = await _directory();
    final path = _path(root, session, 'state.json');
    await _assertPlain(path);
    final temporary = _path(root, session, 'dart-state.tmp');
    await _assertPlain(temporary);
    await File(temporary).writeAsString(
      jsonEncode({
        'version': 1,
        'nonce': session.nonce,
        'phase': phase,
        'cleanupConfirmed': cleanupConfirmed,
      }),
      flush: true,
    );
    await File(temporary).rename(path);
  }

  @override
  Future<void> abortReservation(WindowsSession session) =>
      _writeNotLaunched(session);

  @override
  Future<WindowsSessionSnapshot?> snapshot(WindowsSession session) async {
    if (_released.contains(session.nonce)) {
      return const WindowsSessionSnapshot('stopped', cleanupConfirmed: true);
    }
    final root = await _directory();
    final state = await _read(_path(root, session, 'state.json'));
    if (state == null) return null;
    if (state['version'] != 1 ||
        state['nonce'] != session.nonce ||
        ![
          'prepared',
          'launching',
          'running',
          'stopping',
          'stopped',
          'failed',
        ].contains(state['phase']) ||
        state['cleanupConfirmed'] is! bool)
      _invalid();
    return WindowsSessionSnapshot(
      state['phase'] as String,
      cleanupConfirmed: state['cleanupConfirmed'] as bool,
      reasonCode: state['reasonCode'] is String
          ? state['reasonCode'] as String
          : null,
      coreExitCode: state['coreExitCode'] is int
          ? state['coreExitCode'] as int
          : null,
      connectElapsedMs: state['connectElapsedMs'] is int
          ? state['connectElapsedMs'] as int
          : null,
    );
  }

  @override
  Future<bool> authenticatedReady(WindowsSession session) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 1)
      ..findProxy = (_) => 'DIRECT';
    try {
      for (final authorized in [false, true]) {
        final request = await client
            .getUrl(Uri.parse('http://127.0.0.1:9090/version'))
            .timeout(const Duration(seconds: 2));
        if (authorized)
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${session.nonce}',
          );
        final response = await request.close().timeout(
          const Duration(seconds: 2),
        );
        if (response.statusCode != (authorized ? 200 : 401)) return false;
        final body = await response
            .fold<List<int>>([], (bytes, chunk) {
              if (bytes.length + chunk.length > 4096)
                throw const FormatException();
              return bytes..addAll(chunk);
            })
            .timeout(const Duration(seconds: 2));
        if (authorized) {
          final value = jsonDecode(utf8.decode(body));
          if (value is! Map ||
              value['version'] is! String ||
              !RegExp(
                r'^sing-box \d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.\-]+)?$',
              ).hasMatch(value['version'] as String))
            return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> signalStop(WindowsSession session) async {
    if (_released.contains(session.nonce)) return;
    final root = await _directory();
    final path = _path(root, session, 'stop');
    await _assertPlain(path);
    await File(path).writeAsString(session.nonce, flush: true);
    if (_reservedHere.contains(session.nonce)) return;
    final journal = _path(root, session, 'proxy-recovery.json');
    await _assertPlain(journal);
    // Legacy sessions have no durable rollback/job proof. Leave their state
    // untouched and require the original supervisor's cleanup acknowledgement.
    if (!await File(journal).exists()) return;
    final script = File(
      '${_installedDirectory().path}/windows_vpn_supervisor.ps1',
    );
    await _assertPlain(script.path);
    if (!await script.exists()) _invalid();
    final quotedScript = script.path.replaceAll("'", "''");
    final request = _path(root, session, 'request.json').replaceAll("'", "''");
    final command = "& '$quotedScript' -Request '$request' -RecoverProxy";
    final result = await _run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      base64Encode(utf16le(command)),
    ], timeout: const Duration(seconds: 10));
    if (result.exitCode != 0) _invalid();
    // Native recovery may decline while the exact supervisor/job is alive.
    // Only its separately validated stopped+cleanupConfirmed state is an ACK.
  }

  @override
  Future<void> release(WindowsSession session) async {
    if (_released.contains(session.nonce)) return;
    final finalState = await snapshot(session);
    if (finalState?.stopped != true) _invalid();
    final root = await _directory();
    final pointer = await _read('${root.path}/active.json');
    if (pointer?['nonce'] != session.nonce) _invalid();
    final directory = Directory('${root.path}/${session.nonce}');
    await _assertPlain(directory.path);
    // Preserve a tiny credential-free report even after removing this session's
    // config. Failure to write diagnostics cannot undo confirmed VPN cleanup.
    try {
      final reportPath = '${root.path}/last-windows-vpn-session.json';
      await _assertPlain(reportPath);
      await File(reportPath).writeAsString(
        jsonEncode(finalState!.safeDiagnosticReport()),
        flush: true,
      );
    } catch (_) {}
    // Leave the cleanup acknowledgement discoverable until credentials are
    // removed. A crash during release can retry without losing ownership proof.
    final config = File(_path(root, session, 'config.json'));
    await _assertPlain(config.path);
    if (await config.exists()) await config.delete();
    await File('${root.path}/active.json').delete();
    _released.add(session.nonce);
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Only a noncredential request/acknowledgement remains; VPN is stopped.
    }
  }

  @override
  Future<void> pause(Duration duration) => Future.delayed(duration);
}
