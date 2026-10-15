import 'dart:async';
import 'dart:io' show Socket;
import 'dart:math' show Random;

import 'package:flutter/services.dart';

import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../settings/data/models/app_settings.dart';
import '../../domain/entities/vpn_core_status.dart';
import '../builders/apple_config_builder.dart';
import '../singbox/geo_data_manager.dart';
import '../singbox/provider_geo_bundle.dart';

enum AppleVpnFailure { unavailable, proxyMode }

class AppleVpnException implements Exception {
  final AppleVpnFailure failure;
  const AppleVpnException(this.failure);
}

/// Apple VPN is owned by Network Extension, independently of the Flutter window.
/// A host-only build remains unavailable until the signed provider and core are
/// embedded; it must never fall through to the Windows process launcher.
class AppleVpnDatasource {
  ProviderGeoBundle? _providerRouting;
  void bindProviderRouting(ProviderGeoBundle? bundle) => _providerRouting = bundle;

  static const connectionFailedMessage = 'Apple VPN could not connect.';
  AppleVpnDatasource({
    required this.onStatusChanged,
    this.onError,
    MethodChannel? channel,
    Stream<dynamic>? statusEvents,
    Future<Map<String, String>> Function()? prepareGeo,
    String Function()? createSessionId,
    // Native's provider deadline is two seconds after preference loading. The
    // outer RPC budget must also allow IPC/loading overhead and its fallback.
    Duration statusTimeout = const Duration(seconds: 3),
  }) : _channel = channel ?? const MethodChannel('ru.honeyvpn.proxy/apple_vpn'),
       _statusEvents = statusEvents,
       _prepareGeo = prepareGeo ?? GeoDataManager.ensureReady,
       _createSessionId = createSessionId ?? _newSessionId,
       _statusTimeout = statusTimeout;

  final void Function(VpnCoreStatus) onStatusChanged;
  final void Function(String)? onError;
  final MethodChannel _channel;
  final Stream<dynamic>? _statusEvents;
  final Future<Map<String, String>> Function() _prepareGeo;
  final String Function() _createSessionId;
  final Duration _statusTimeout;
  static const _events = EventChannel('ru.honeyvpn.proxy/apple_vpn_status');
  StreamSubscription<dynamic>? _subscription;
  bool _ready = false;
  bool _disposed = false;
  bool _failed = false;
  bool _connecting = false;
  bool _started = false;
  bool _stopping = false;
  bool _startingHere = false;
  bool _submittedStart = false;
  bool _adoptedSession = false;
  int? _requestedProfileId;
  String? _expectedSessionId;
  VpnCoreStatus? _lastStatus;

  VpnCoreStatus? get lastStatus => _lastStatus;

  Future<void> initialize() async {
    try {
      _ready = await _channel.invokeMethod<bool>('initialize') ?? false;
    } on MissingPluginException {
      _ready = false;
    } on PlatformException catch (error) {
      if (error.code != 'CORE_UNAVAILABLE') rethrow;
      _ready = false;
    }
    if (!_ready) throw const AppleVpnException(AppleVpnFailure.unavailable);
  }

  Future<bool> requestPermission() async {
    if (_disposed) return false;
    if (!_ready) await initialize();
    if (_disposed) return false;
    return await _channel.invokeMethod<bool>('requestPermission') ?? false;
  }

  Future<void> start(
    ParsedProxy proxy, {
    ConnectionMode mode = ConnectionMode.tunnel,
    AppSettings settings = const AppSettings(),
    int? profileId,
  }) async {
    if (_disposed) return;
    if (mode != ConnectionMode.tunnel ||
        settings.connectionMode != ConnectionMode.tunnel) {
      throw const AppleVpnException(AppleVpnFailure.proxyMode);
    }
    if (profileId == null || profileId <= 0) {
      throw ArgumentError.value(profileId, 'profileId', 'Must be positive');
    }
    if (!_ready) await initialize();
    final geoPaths = await _prepareGeo();
    if (_disposed) return;
    final config = AppleConfigBuilder(
      geoPaths: geoPaths,
      providerRouting: _providerRouting,
    ).generate(proxy, settings);
    final sessionId = _createSessionId().toLowerCase();
    if (!_sessionPattern.hasMatch(sessionId)) {
      throw ArgumentError('Invalid session UUID');
    }
    _failed = false;
    _connecting = false;
    _started = false;
    _stopping = false;
    _startingHere = true;
    _submittedStart = false;
    _adoptedSession = false;
    _requestedProfileId = profileId;
    _expectedSessionId = sessionId;
    _lastStatus = null;
    _listen();
    try {
      await _channel.invokeMethod<void>('start', {
        'config': config,
        'profileId': profileId,
        'sessionId': sessionId,
      });
      _submittedStart = true;
    } catch (_) {
      await _subscription?.cancel();
      _subscription = null;
      rethrow;
    }
    // Completion of start() means only that the request was submitted. The
    // native NEVPNStatusDidChange event is the authority for CONNECTED.
  }

  Future<bool> checkRunning() async {
    final status = await getStatus();
    if (status != null) return status.state == 'CONNECTED';
    try {
      return await _channel
              .invokeMethod<bool>('checkStatus')
              .timeout(_statusTimeout) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  /// A read-only OS snapshot. Core readiness gates new starts, not discovery of
  /// an already-running OS-owned session after the Flutter window is reopened.
  Future<VpnCoreStatus?> getStatus() async {
    if (_disposed) return null;
    try {
      final value = await _channel
          .invokeMethod<dynamic>('getStatus')
          .timeout(_statusTimeout);
      if (_disposed || value is! Map) return null;
      final status = _parseStatus(value);
      if (status != null) {
        if (_startingHere && !_acceptIdentity(value, status)) return null;
        _lastStatus = status;
        if (!_startingHere) _expectedSessionId = status.sessionId;
      }
      return status;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  void reattach() {
    _failed = false;
    _connecting = _lastStatus?.state == 'CONNECTING';
    _started = _lastStatus?.state == 'CONNECTED';
    _stopping = false;
    _startingHere = false;
    _adoptedSession = true;
    _requestedProfileId = null;
    _listen();
  }

  void _listen() {
    if (_disposed || _subscription != null) return;
    _subscription = (_statusEvents ?? _events.receiveBroadcastStream()).listen(
      (dynamic event) {
        if (_disposed || _failed || _stopping || event is! Map) return;
        if (event['event'] == 'error') {
          _failed = true;
          final message = event['message'];
          onError?.call(message is String ? message : 'Apple VPN error');
          return;
        }
        final status = _parseStatus(event, allowLegacyEvents: true);
        if (status == null || !_acceptIdentity(event, status)) return;
        switch (status.state) {
          case 'CONNECTING':
            _connecting = true;
            _started = false;
            _lastStatus = status;
            onStatusChanged(status);
          case 'CONNECTED':
            _connecting = false;
            _started = true;
            _lastStatus = status;
            onStatusChanged(status);
          case 'DISCONNECTING':
            _lastStatus = status;
            onStatusChanged(status);
          case 'DISCONNECTED':
            if (_startingHere && _connecting && !_started) {
              _failed = true;
              onError?.call(connectionFailedMessage);
            } else if (_startingHere && !_connecting && !_started) {
              // EventChannel's initial stopped baseline precedes start().
              return;
            } else {
              _connecting = false;
              _started = false;
              _expectedSessionId = null;
              _lastStatus = status;
              onStatusChanged(status);
            }
        }
      },
      onError: (Object error) {
        if (_disposed || _failed) return;
        _failed = true;
        onError?.call('Apple VPN status unavailable');
      },
    );
  }

  Future<void> stop() async {
    _stopping = true;
    if (!_submittedStart && !_adoptedSession) {
      // A rejected/unsubmitted request does not own an OS session. In
      // particular, native may have refused start because a different session
      // appeared after discovery. Cleanup must detach, never stop that tunnel.
      await _subscription?.cancel();
      _subscription = null;
      return;
    }
    try {
      await _channel.invokeMethod<void>('stop');
      _submittedStart = false;
      _adoptedSession = false;
      _lastStatus = const VpnCoreStatus(
        state: 'DISCONNECTED',
        usesNativeSessionIdentity: true,
        trafficAvailable: false,
        ratesAvailable: false,
      );
      _expectedSessionId = null;
    } finally {
      await _subscription?.cancel();
      _subscription = null;
    }
  }

  bool _acceptIdentity(Map<dynamic, dynamic> packet, VpnCoreStatus status) {
    final event = packet['event'];
    // Stopped state exposes no active identity, but a tagged late stopped
    // packet can still be rejected before it clears the current session.
    final packetSession =
        packet['sessionId'] is String &&
            _sessionPattern.hasMatch(packet['sessionId'] as String)
        ? (packet['sessionId'] as String).toLowerCase()
        : null;
    final packetProfile = packet['profileId'];
    if (_requestedProfileId != null &&
        packetProfile is int &&
        packetProfile > 0 &&
        packetProfile != _requestedProfileId)
      return false;
    if (_startingHere) {
      if (packetSession != null && packetSession != _expectedSessionId) {
        return false;
      }
      // A late event for a previous session of the same saved profile must
      // never bind the new request. OS transition events without a provider
      // identity remain useful, but connected telemetry needs exact identity.
      if (status.state == 'CONNECTED' &&
          (status.sessionId != _expectedSessionId ||
              status.profileId != _requestedProfileId)) {
        return false;
      }
    }
    if (_expectedSessionId != null &&
        packetSession != null &&
        packetSession != _expectedSessionId &&
        (event == 'stats' ||
            event == 'stopped' ||
            event == 'disconnecting' ||
            (_startingHere && event == 'started')))
      return false;
    if (status.sessionId != null && status.state != 'DISCONNECTED') {
      _expectedSessionId = status.sessionId;
    }
    return true;
  }

  static VpnCoreStatus? _parseStatus(
    Map<dynamic, dynamic> value, {
    bool allowLegacyEvents = false,
  }) {
    final versioned = value['version'] == 1;
    final event = value['event'];
    // Older bridges may emit OS transitions but have no identity/counter
    // protocol. Preserve that state honestly without borrowing saved selection.
    if (!versioned &&
        !(allowLegacyEvents &&
            value['version'] == null &&
            [
              'started',
              'connecting',
              'disconnecting',
              'stopped',
            ].contains(event))) {
      return null;
    }
    final state = switch (event) {
      'started' || 'stats' => 'CONNECTED',
      'connecting' => 'CONNECTING',
      'disconnecting' => 'DISCONNECTING',
      'stopped' => 'DISCONNECTED',
      _ => null,
    };
    if (state == null ||
        (versioned && state == 'CONNECTED' && value['running'] != true)) {
      return null;
    }
    final traffic =
        versioned &&
        state == 'CONNECTED' &&
        value['trafficAvailable'] == true &&
        _validTotal(value['uplinkTotal']) &&
        _validTotal(value['downlinkTotal']);
    final rates =
        traffic &&
        value['ratesAvailable'] == true &&
        _validNumber(value['uplink']) &&
        _validNumber(value['downlink']);
    final sessionId =
        versioned &&
            state != 'DISCONNECTED' &&
            value['sessionId'] is String &&
            _sessionPattern.hasMatch(value['sessionId'] as String)
        ? (value['sessionId'] as String).toLowerCase()
        : null;
    return VpnCoreStatus(
      state: state,
      duration: _duration(_counter(value['duration'])),
      upload: traffic ? _counter(value['uplinkTotal']) : 0,
      download: traffic ? _counter(value['downlinkTotal']) : 0,
      uploadSpeed: rates ? _counter(value['uplink']) : 0,
      downloadSpeed: rates ? _counter(value['downlink']) : 0,
      trafficAvailable: traffic,
      ratesAvailable: rates,
      usesNativeSessionIdentity: true,
      profileId:
          sessionId != null &&
              value['profileId'] is int &&
              value['profileId'] > 0
          ? value['profileId'] as int
          : null,
      sessionId: sessionId,
    );
  }

  static final _sessionPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static String _newSessionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static bool _validNumber(dynamic value) =>
      value is num && value.isFinite && value >= 0;
  static bool _validTotal(dynamic value) => value is int && value >= 0;
  Future<int> ping(ParsedProxy proxy) async {
    Socket? socket;
    try {
      final timer = Stopwatch()..start();
      socket = await Socket.connect(
        proxy.host,
        proxy.port,
        timeout: const Duration(seconds: 5),
      );
      return timer.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      await socket?.close();
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  static int _counter(dynamic value) =>
      value is num && value.isFinite && value > 0 ? value.toInt() : 0;

  static String _duration(int seconds) =>
      '${(seconds ~/ 3600).toString().padLeft(2, '0')}:'
      '${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}:'
      '${(seconds % 60).toString().padLeft(2, '0')}';
}
