import 'dart:async';

import 'package:flutter_v2ray/flutter_v2ray.dart';

import '../singbox/xray_config_generator.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';

class VpnDatasource {
  VpnDatasource({required void Function(V2RayStatus) onStatusChanged})
      : _v2ray = FlutterV2ray(onStatusChanged: onStatusChanged);

  final FlutterV2ray _v2ray;
  final _statsController = StreamController<Map<String, dynamic>>.broadcast();

  Future<void> initialize() async {
    await _v2ray.initializeV2Ray(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
    );
  }

  Future<bool> requestPermission() => _v2ray.requestPermission();

  Future<void> start(ParsedProxy proxy) async {
    final config = const XrayConfigGenerator().generate(proxy);
    await _v2ray.startV2Ray(
      remark: proxy.displayName,
      config: config,
      notificationDisconnectButtonName: 'Disconnect',
    );
  }

  Future<void> stop() => _v2ray.stopV2Ray();

  Future<int> ping(ParsedProxy proxy) async {
    final config = const XrayConfigGenerator().generate(proxy);
    return _v2ray.getServerDelay(config: config);
  }

  void dispose() {
    _statsController.close();
  }
}

// Keep the old name as an alias so connection_notifier.dart compiles without change
typedef SingboxDatasource = VpnDatasource;

// AppSettings used by SingboxConfigGenerator (kept for backward compatibility)
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
