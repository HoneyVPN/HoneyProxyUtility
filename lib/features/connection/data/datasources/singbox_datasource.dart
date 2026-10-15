import 'dart:async';
import 'dart:io' show Platform, Socket;

import 'package:flutter/services.dart';
import '../../domain/entities/vpn_core_status.dart';
import 'package:logging/logging.dart';

import '../singbox/geo_data_manager.dart';
import '../singbox/provider_geo_bundle.dart';
import '../singbox/singbox_config_generator.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../settings/data/models/app_settings.dart';
import 'vpn_datasource_windows.dart';
import 'apple_vpn_datasource.dart';
import '../../../diagnostics/data/diagnostic_android.dart';

final _log = Logger('VpnDatasource');

enum VpnPlatform { android, windows, apple, unsupported }

VpnPlatform get currentVpnPlatform {
  if (Platform.isAndroid) return VpnPlatform.android;
  if (Platform.isWindows) return VpnPlatform.windows;
  if (Platform.isMacOS || Platform.isIOS) return VpnPlatform.apple;
  return VpnPlatform.unsupported;
}

class VpnDatasource {
  static const nativeStatusUnavailableMessage =
      'ANDROID_VPN_STATUS_UNAVAILABLE';
  VpnDatasource({
    required void Function(VpnCoreStatus) onStatusChanged,
    this.onError,
    VpnPlatform? platform,
  }) : _onStatus = onStatusChanged,
       _platform = platform ?? currentVpnPlatform,
       _windows = (platform ?? currentVpnPlatform) == VpnPlatform.windows
           ? WindowsVpnDatasource(
               onStatusChanged: onStatusChanged,
               onError: onError,
             )
           : null,
       _apple = (platform ?? currentVpnPlatform) == VpnPlatform.apple
           ? AppleVpnDatasource(
               onStatusChanged: onStatusChanged,
               onError: onError,
             )
           : null;

  final void Function(VpnCoreStatus) _onStatus;
  final void Function(String message)? onError;
  final WindowsVpnDatasource? _windows;
  final AppleVpnDatasource? _apple;
  final VpnPlatform _platform;
  StreamSubscription<dynamic>? _statsSubscription;
  int? _profileId;
  ProviderGeoBundle? _providerRouting;

  /// Immutable session input, independent of future subscription refreshes.
  /// Binding does not alter any running native configuration.
  void bindProviderRouting(ProviderGeoBundle? bundle) {
    _providerRouting = bundle;
    _windows?.bindProviderRouting(bundle);
    _apple?.bindProviderRouting(bundle);
  }

  static const _vpnChannel = MethodChannel('ru.honeyvpn.proxy/vpn');
  static const _statsChannel = EventChannel('ru.honeyvpn.proxy/vpn_stats');

  bool get _isMobile => _platform == VpnPlatform.android;

  /// Apple sessions can outlive this window; discover OS ownership before a
  /// new request decides which session it is allowed to stop.
  bool get requiresNativeSessionDiscovery => _apple != null;

  /// Bind saved profile identity independently of start's existing overrides.
  /// Only the Apple native session transport consumes this value.
  void bindProfile(int profileId) {
    if (profileId <= 0) {
      throw ArgumentError.value(profileId, 'profileId', 'Must be positive');
    }
    _profileId = profileId;
  }

  Future<void> initialize() async {
    if (_apple != null) return _apple.initialize();
    if (_windows != null) return _windows.initialize();
    if (!_isMobile) throw UnsupportedError('platform');
  }

  Future<bool> requestPermission() async {
    if (_apple != null) return _apple.requestPermission();
    if (_isMobile) {
      final result = await _vpnChannel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    }
    if (_windows != null) return _windows.requestPermission();
    throw UnsupportedError('platform');
  }

  Future<void> start(
    ParsedProxy proxy, {
    ConnectionMode mode = ConnectionMode.tunnel,
    AppSettings settings = const AppSettings(),
  }) async {
    if (_apple != null) {
      return _apple.start(
        proxy,
        mode: mode,
        settings: settings,
        profileId: _profileId,
      );
    }
    if (_isMobile) {
      const SingboxConfigGenerator().validateTargetCompatibility(proxy);
      final geoPaths = usesBuiltInGeo(settings)
          ? await GeoDataManager.ensureReady()
          : <String, String>{};
      final config = SingboxConfigGenerator(
        geoPaths: geoPaths,
        providerRouting: _providerRouting,
      ).generateForAndroid(proxy, settings);
      _listenToStats();
      await _vpnChannel.invokeMethod<void>('start', {
        'config': config,
        'locale': settings.locale == 'ru' ? 'ru' : 'en',
      });
    } else if (_windows != null) {
      await _windows.start(proxy, mode: mode, settings: settings);
    } else {
      throw UnsupportedError('platform');
    }
  }

  void _listenToStats() {
    _statsSubscription?.cancel();
    _statsSubscription = _statsChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final eventType = event['event'] as String?;
        switch (eventType) {
          case 'started':
            _onStatus(VpnCoreStatus(state: 'CONNECTED'));
          case 'stats':
            _onStatus(
              VpnCoreStatus(
                state: 'CONNECTED',
                uploadSpeed: (event['uplink'] as num? ?? 0).toInt(),
                downloadSpeed: (event['downlink'] as num? ?? 0).toInt(),
                upload: (event['uplinkTotal'] as num? ?? 0).toInt(),
                download: (event['downlinkTotal'] as num? ?? 0).toInt(),
                duration: _formatDuration(event['duration'] as int? ?? 0),
              ),
            );
          case 'error':
            unawaited(readAndroidDiagnostics());
            final msg = event['message'] as String? ?? 'Unknown VPN error';
            onError?.call(msg);
          case 'stopped':
            _onStatus(VpnCoreStatus(state: 'DISCONNECTED'));
          case 'stopping':
            _onStatus(VpnCoreStatus(state: 'DISCONNECTING'));
        }
      },
      onError: (e) {
        _log.warning('VPN stats stream error', e);
        onError?.call(nativeStatusUnavailableMessage);
      },
    );
  }

  static String _formatDuration(int seconds) {
    final h = (seconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// Returns true if the native VPN service reports it is currently running.
  /// Used on app launch to restore connection state without calling [start].
  Future<bool> checkRunning() async {
    if (_apple != null) return _apple.checkRunning();
    if (_windows != null) return _windows.checkRunning();
    if (!_isMobile) return false;
    try {
      return await _vpnChannel.invokeMethod<bool>('checkStatus') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Discover an existing session without readiness checks/profile writes.
  /// Legacy non-Apple sources keep their bool discovery contract.
  Future<VpnCoreStatus?> readCurrentStatus() async {
    if (_apple != null) return _apple.getStatus();
    if (_isMobile) {
      try {
        final status = await _vpnChannel.invokeMapMethod<String, dynamic>(
          'getStatus',
        );
        final state = status?['state'];
        if (state is String &&
            const {
              'CONNECTING',
              'CONNECTED',
              'DISCONNECTING',
              'DISCONNECTED',
            }.contains(state)) {
          return VpnCoreStatus(state: state);
        }
      } on MissingPluginException {
        // Compatibility with an older installed Android service.
      }
    }
    if (_windows != null) return _windows.readCurrentStatus();
    if (await checkRunning()) return const VpnCoreStatus(state: 'CONNECTED');
    return null;
  }

  /// Re-subscribes to the stats EventChannel without starting a new VPN session.
  /// Call after [checkRunning] returns true to restore the live stats stream.
  void reattach() {
    _apple?.reattach();
    _windows?.reattach();
    if (_isMobile) _listenToStats();
  }

  Future<void> stop() async {
    if (_apple != null) return _apple.stop();
    if (_isMobile) {
      await _statsSubscription?.cancel();
      _statsSubscription = null;
      await _vpnChannel.invokeMethod<void>('stop');
    } else if (_windows != null) {
      await _windows.stop();
    }
  }

  Future<int> ping(ParsedProxy proxy) async {
    if (_apple != null) return _apple.ping(proxy);
    if (_windows != null) return _windows.ping(proxy);
    if (!_isMobile) return -1;

    Socket? sock;
    try {
      final sw = Stopwatch()..start();
      sock = await Socket.connect(
        proxy.host,
        proxy.port,
        timeout: const Duration(seconds: 5),
      );
      sw.stop();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      await sock?.close();
    }
  }

  void dispose() {
    _statsSubscription?.cancel();
    _windows?.dispose();
    _apple?.dispose();
  }
}

typedef SingboxDatasource = VpnDatasource;
