import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../../subscriptions/domain/entities/provider_geo_state.dart';
import 'windows_session.dart';

typedef WindowsServiceRequest = Future<String> Function(String request);

/// The native boundary authenticates the pipe against the registered SCM
/// service before sending a configuration. The service owns every TUN resource.
class ServiceWindowsSessionBackend implements WindowsSessionBackend {
  ServiceWindowsSessionBackend({
    WindowsServiceRequest? request,
    Future<bool> Function(WindowsSession session)? authenticatedReady,
  }) : _request = request ?? _nativeRequest,
       _authenticatedReady =
           authenticatedReady ?? FileWindowsSessionBackend().authenticatedReady;

  final WindowsServiceRequest _request;
  final Future<bool> Function(WindowsSession) _authenticatedReady;
  final Stopwatch _clock = Stopwatch()..start();
  static const _channel = MethodChannel('ru.honeyvpn.proxy/windows_service');
  static const _maxRequestBytes = 1024 * 1024;
  static const _maxReplyBytes = 1024 * 1024;
  static final _nonce = RegExp(r'^[a-f0-9]{64}$');
  static final _ticks = RegExp(r'^[1-9][0-9]{0,19}$');
  static final _providerTag = RegExp(
    r'^pgeo-[a-f0-9]{16}-[a-f0-9]{16}-(?:block|proxy|direct)$',
  );

  static Future<String> _nativeRequest(String request) async {
    try {
      final reply = await _channel
          .invokeMethod<String>('request', request)
          .timeout(const Duration(seconds: 10));
      if (reply == null) _invalid();
      return reply;
    } on PlatformException catch (error) {
      throw WindowsSessionException(switch (error.code) {
        'serviceAccessDenied' => WindowsSessionFailure.serviceAccessDenied,
        'serviceNotInstalled' => WindowsSessionFailure.serviceNotInstalled,
        _ => WindowsSessionFailure.serviceUnavailable,
      });
    } on MissingPluginException {
      throw const WindowsSessionException(
        WindowsSessionFailure.serviceUnavailable,
      );
    } on TimeoutException {
      throw const WindowsSessionException(
        WindowsSessionFailure.serviceUnavailable,
      );
    }
  }

  static Never _invalid() => throw const WindowsSessionException(
    WindowsSessionFailure.recoveryRequired,
  );

  static bool _hasProviderInlineRules(Object? config) {
    if (config is! Map) return false;
    final route = config['route'];
    if (route is! Map) return false;
    final sets = route['rule_set'];
    if (sets is! List) return false;
    return sets.any((set) {
      if (set is! Map || set['type'] != 'inline') return false;
      final tag = set['tag'];
      return tag is String && _providerTag.hasMatch(tag);
    });
  }

  static String _encodeRequest(
    String operation,
    WindowsSession? session,
    Map<String, dynamic> arguments,
  ) {
    final request = jsonEncode({
      'version': 1,
      'operation': operation,
      if (session != null) 'nonce': session.nonce,
      ...arguments,
    });
    // The native limit covers the complete UTF-8 payload, not just config or
    // Dart's character count. Send this same checked string across the bridge.
    if (utf8.encode(request).length > _maxRequestBytes) {
      if (operation == 'reserve' &&
          _hasProviderInlineRules(arguments['config'])) {
        throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
      }
      throw const WindowsSessionException(WindowsSessionFailure.startFailed);
    }
    return request;
  }

  Future<Object?> _call(
    String operation, {
    WindowsSession? session,
    Map<String, dynamic> arguments = const {},
  }) async {
    if (session != null &&
        (!session.serviceOwned || !_nonce.hasMatch(session.nonce))) {
      _invalid();
    }
    try {
      final reply = await _request(
        _encodeRequest(operation, session, arguments),
      ).timeout(const Duration(seconds: 10));
      if (utf8.encode(reply).length > _maxReplyBytes) _invalid();
      final decoded = jsonDecode(reply);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['ok'] is! bool) {
        _invalid();
      }
      if (decoded['ok'] != true) {
        final code = decoded['code'];
        final failure = WindowsSessionFailure.values
            .where((failure) => failure.name == code)
            .firstOrNull;
        throw WindowsSessionException(
          failure ?? WindowsSessionFailure.recoveryRequired,
        );
      }
      if (!decoded.containsKey('result')) _invalid();
      return decoded['result'];
    } on ProviderGeoException {
      rethrow;
    } on WindowsSessionException {
      rethrow;
    } catch (_) {
      // Paths, credentials and server exceptions never become product text.
      _invalid();
    }
  }

  static WindowsSession _session(Object? response) {
    if (response is! Map<String, dynamic>) _invalid();
    final nonce = response['nonce'];
    final parent = response['parentPid'];
    final ticks = response['parentStartTicks'];
    if (nonce is! String ||
        !_nonce.hasMatch(nonce) ||
        parent is! int ||
        parent <= 0 ||
        parent > 0xffffffff ||
        ticks is! String ||
        !_ticks.hasMatch(ticks)) {
      _invalid();
    }
    return WindowsSession(
      nonce: nonce,
      parentPid: parent,
      parentStartTicks: ticks,
      serviceOwned: true,
    );
  }

  @override
  Duration get monotonicTime => _clock.elapsed;

  @override
  Future<WindowsSession?> readActive() async {
    final response = await _call('readActive');
    return response == null ? null : _session(response);
  }

  @override
  Future<bool> parentAlive(WindowsSession session) async {
    final response = await _call('parentAlive', session: session);
    if (response is! bool) _invalid();
    return response;
  }

  @override
  Future<WindowsSession> reserve(
    Map<String, dynamic> config, {
    required bool tunnel,
    required int httpPort,
    String? proxyIp,
  }) async {
    if (!tunnel) _invalid();
    return _session(
      await _call(
        'reserve',
        arguments: {
          'config': config,
          // Retained for the shared supervisor schema, not a TUN listener.
          // Saved user-mode proxy ports do not apply to this service session.
          'httpPort': 2081,
          if (proxyIp != null) 'proxyIp': proxyIp,
        },
      ),
    );
  }

  Future<void> _command(String operation, WindowsSession session) async {
    if (await _call(operation, session: session) != null) _invalid();
  }

  @override
  Future<void> launch(WindowsSession session, {required bool elevated}) =>
      _command('launch', session);
  @override
  Future<void> abortReservation(WindowsSession session) =>
      _command('abortReservation', session);
  @override
  Future<void> signalStop(WindowsSession session) =>
      _command('signalStop', session);
  @override
  Future<void> release(WindowsSession session) => _command('release', session);

  @override
  Future<WindowsSessionSnapshot?> snapshot(WindowsSession session) async {
    final response = await _call('snapshot', session: session);
    if (response == null) return null;
    if (response is! Map<String, dynamic> ||
        response['cleanupConfirmed'] is! bool)
      _invalid();
    final phase = response['phase'];
    if (phase is! String ||
        !const {
          'prepared',
          'launching',
          'starting',
          'running',
          'stopping',
          'stopped',
          'failed',
        }.contains(phase))
      _invalid();
    for (final key in ['coreExitCode', 'connectElapsedMs']) {
      if (response[key] != null && response[key] is! int) _invalid();
    }
    return WindowsSessionSnapshot(
      phase,
      cleanupConfirmed: response['cleanupConfirmed'] as bool,
      reasonCode: response['reasonCode'] is String
          ? response['reasonCode'] as String
          : null,
      coreExitCode: response['coreExitCode'] as int?,
      connectElapsedMs: response['connectElapsedMs'] as int?,
    );
  }

  @override
  Future<bool> authenticatedReady(WindowsSession session) =>
      _authenticatedReady(session);
  @override
  Future<void> pause(Duration duration) => Future<void>.delayed(duration);
}

/// Proxy runs in the user's own account. Only TUN crosses the service boundary.
/// Recovery examines both stores; competing sessions never get silently picked.
class HybridWindowsSessionBackend implements WindowsSessionBackend {
  HybridWindowsSessionBackend({
    WindowsSessionBackend? proxyBackend,
    WindowsSessionBackend? serviceBackend,
  }) : _proxy = proxyBackend ?? FileWindowsSessionBackend(),
       _service = serviceBackend ?? ServiceWindowsSessionBackend();

  final WindowsSessionBackend _proxy;
  final WindowsSessionBackend _service;
  final Stopwatch _clock = Stopwatch()..start();
  WindowsSessionBackend _backend(WindowsSession session) =>
      session.serviceOwned ? _service : _proxy;
  @override
  Duration get monotonicTime => _clock.elapsed;

  @override
  Future<WindowsSession?> readActive() async {
    final proxy = await _proxy.readActive();
    WindowsSession? service;
    try {
      service = await _service.readActive();
    } on WindowsSessionException catch (error) {
      if (error.failure != WindowsSessionFailure.serviceNotInstalled) rethrow;
      // Only confirmed absence permits proxy-only use without the installer.
      // An installed service with unavailable state might still own a TUN.
    }
    if (proxy != null && service != null) {
      throw const WindowsSessionException(
        WindowsSessionFailure.recoveryRequired,
      );
    }
    return service ?? proxy;
  }

  @override
  Future<WindowsSession> reserve(
    Map<String, dynamic> config, {
    required bool tunnel,
    required int httpPort,
    String? proxyIp,
  }) => (tunnel ? _service : _proxy).reserve(
    config,
    tunnel: tunnel,
    httpPort: httpPort,
    proxyIp: proxyIp,
  );
  @override
  Future<bool> parentAlive(WindowsSession session) =>
      _backend(session).parentAlive(session);
  @override
  Future<void> launch(WindowsSession session, {required bool elevated}) =>
      _backend(session).launch(session, elevated: session.serviceOwned);
  @override
  Future<void> abortReservation(WindowsSession session) =>
      _backend(session).abortReservation(session);
  @override
  Future<WindowsSessionSnapshot?> snapshot(WindowsSession session) =>
      _backend(session).snapshot(session);
  @override
  Future<bool> authenticatedReady(WindowsSession session) =>
      _backend(session).authenticatedReady(session);
  @override
  Future<void> signalStop(WindowsSession session) =>
      _backend(session).signalStop(session);
  @override
  Future<void> release(WindowsSession session) =>
      _backend(session).release(session);
  @override
  Future<void> pause(Duration duration) => Future<void>.delayed(duration);
}
