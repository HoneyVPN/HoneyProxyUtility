import 'dart:async';
import 'dart:io' show Platform, Socket;

import 'package:flutter/services.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';

import '../singbox/singbox_config_generator.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../settings/data/models/app_settings.dart';
import 'vpn_datasource_windows.dart';

class VpnDatasource {
  VpnDatasource({required void Function(V2RayStatus) onStatusChanged})
      : _onStatus = onStatusChanged,
        _windows = (!Platform.isAndroid && !Platform.isIOS)
            ? WindowsVpnDatasource(onStatusChanged: onStatusChanged)
            : null;

  final void Function(V2RayStatus) _onStatus;
  final WindowsVpnDatasource? _windows;
  StreamSubscription<dynamic>? _statsSubscription;

  static const _vpnChannel  = MethodChannel('ru.honeyvpn.proxy/vpn');
  static const _statsChannel = EventChannel('ru.honeyvpn.proxy/vpn_stats');

  bool get _isAndroid => Platform.isAndroid || Platform.isIOS;

  Future<void> initialize() async {
    if (!_isAndroid) await _windows!.initialize();
  }

  Future<bool> requestPermission() async {
    if (_isAndroid) {
      final result = await _vpnChannel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    }
    return _windows!.requestPermission();
  }

  Future<void> start(
    ParsedProxy proxy, {
    ConnectionMode mode = ConnectionMode.tunnel,
    AppSettings settings = const AppSettings(),
  }) async {
    if (_isAndroid) {
      final config = const SingboxConfigGenerator().generateForAndroid(proxy, settings);
      _listenToStats();
      await _vpnChannel.invokeMethod<void>('start', {'config': config});
    } else {
      await _windows!.start(proxy, mode: mode);
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
            _onStatus(V2RayStatus(state: 'CONNECTED'));
          case 'stats':
            _onStatus(V2RayStatus(
              state: 'CONNECTED',
              uploadSpeed: (event['uplink'] as num? ?? 0).toInt(),
              downloadSpeed: (event['downlink'] as num? ?? 0).toInt(),
              upload: (event['uplinkTotal'] as num? ?? 0).toInt(),
              download: (event['downlinkTotal'] as num? ?? 0).toInt(),
              duration: _formatDuration(event['duration'] as int? ?? 0),
            ));
          case 'stopped':
            _onStatus(V2RayStatus(state: 'DISCONNECTED'));
        }
      },
      onError: (_) => _onStatus(V2RayStatus(state: 'DISCONNECTED')),
    );
  }

  static String _formatDuration(int seconds) {
    final h = (seconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Future<void> stop() async {
    if (_isAndroid) {
      await _statsSubscription?.cancel();
      _statsSubscription = null;
      await _vpnChannel.invokeMethod<void>('stop');
    } else {
      await _windows!.stop();
    }
  }

  Future<int> ping(ParsedProxy proxy) async {
    if (_isAndroid) {
      try {
        final sw = Stopwatch()..start();
        final sock = await Socket.connect(
          proxy.host, proxy.port,
          timeout: const Duration(seconds: 5),
        );
        sw.stop();
        sock.destroy();
        return sw.elapsedMilliseconds;
      } catch (_) {
        return -1;
      }
    }
    return _windows!.ping(proxy);
  }

  void dispose() {
    _statsSubscription?.cancel();
    _windows?.dispose();
  }
}

typedef SingboxDatasource = VpnDatasource;
