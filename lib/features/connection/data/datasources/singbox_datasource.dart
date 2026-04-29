import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_v2ray/flutter_v2ray.dart';

import '../singbox/xray_config_generator.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';
import 'vpn_datasource_windows.dart';

class VpnDatasource {
  VpnDatasource({required void Function(V2RayStatus) onStatusChanged})
      : _onStatus = onStatusChanged,
        _v2ray = (Platform.isAndroid || Platform.isIOS)
            ? FlutterV2ray(onStatusChanged: onStatusChanged)
            : null,
        _windows = (!Platform.isAndroid && !Platform.isIOS)
            ? WindowsVpnDatasource(onStatusChanged: onStatusChanged)
            : null;

  final void Function(V2RayStatus) _onStatus;
  final FlutterV2ray? _v2ray;
  final WindowsVpnDatasource? _windows;
  final _statsController = StreamController<Map<String, dynamic>>.broadcast();

  bool get _isMobile => _v2ray != null;

  Future<void> initialize() async {
    if (_isMobile) {
      await _v2ray!.initializeV2Ray(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
      );
    } else {
      await _windows!.initialize();
    }
  }

  Future<bool> requestPermission() async {
    if (_isMobile) return _v2ray!.requestPermission();
    return _windows!.requestPermission();
  }

  Future<void> start(ParsedProxy proxy) async {
    if (_isMobile) {
      final config = const XrayConfigGenerator().generate(proxy);
      await _v2ray!.startV2Ray(
        remark: proxy.displayName,
        config: config,
        notificationDisconnectButtonName: 'Disconnect',
      );
    } else {
      await _windows!.start(proxy);
    }
  }

  Future<void> stop() async {
    if (_isMobile) {
      await _v2ray!.stopV2Ray();
    } else {
      await _windows!.stop();
    }
  }

  Future<int> ping(ParsedProxy proxy) async {
    if (_isMobile) {
      final config = const XrayConfigGenerator().generate(proxy);
      return _v2ray!.getServerDelay(config: config);
    }
    return _windows!.ping(proxy);
  }

  void dispose() {
    _statsController.close();
    _windows?.dispose();
  }
}

typedef SingboxDatasource = VpnDatasource;

class AppSettings {
  final bool bypassRU;
  final bool enableFakeIP;
  final String routingMode;
  const AppSettings({
    this.bypassRU = false,
    this.enableFakeIP = true,
    this.routingMode = 'global',
  });
}
