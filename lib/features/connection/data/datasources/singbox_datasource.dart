import 'dart:async';
import 'dart:io' show Platform, Socket;

import 'package:flutter_v2ray/flutter_v2ray.dart';

import '../singbox/xray_config_generator.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../settings/data/models/app_settings.dart';
import 'vpn_datasource_windows.dart';
import 'android_singbox_helper.dart';

bool _xraySupports(ParsedProxy proxy) =>
    proxy is VmessConfig ||
    proxy is VlessConfig ||
    proxy is TrojanConfig ||
    proxy is ShadowsocksConfig;

Map<String, dynamic> _buildAndroidChainConfig(ParsedProxy proxy) => {
  'log': {'level': 'warn'},
  'inbounds': [
    {
      'type': 'socks',
      'tag': 'socks-in',
      'listen': '127.0.0.1',
      'listen_port': AndroidSingboxHelper.chainProxyPort,
    }
  ],
  'outbounds': [_buildSingboxOutbound(proxy)],
};

Map<String, dynamic> _buildSingboxOutbound(ParsedProxy proxy) => switch (proxy) {
  Hysteria2Config c => {
    'type': 'hysteria2',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'password': c.auth,
    'tls': {
      'enabled': true,
      if (c.sni.isNotEmpty) 'server_name': c.sni,
      if (c.insecure) 'insecure': true,
    },
    if (c.obfs.isNotEmpty) 'obfs': {'type': c.obfs, 'password': c.obfsPassword},
  },
  TuicConfig c => {
    'type': 'tuic',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'uuid': c.uuid,
    'password': c.password,
    'tls': {
      'enabled': true,
      if (c.sni.isNotEmpty) 'server_name': c.sni,
      if (c.alpn.isNotEmpty) 'alpn': c.alpn.split(','),
      if (c.allowInsecure) 'insecure': true,
    },
    if (c.congestionControl.isNotEmpty) 'congestion_control': c.congestionControl,
    if (c.udpRelayMode.isNotEmpty) 'udp_relay_mode': c.udpRelayMode,
  },
  WireGuardConfig c => {
    'type': 'wireguard',
    'tag': 'proxy',
    'server': c.host,
    'server_port': c.port,
    'private_key': c.privateKey,
    'peer_public_key': c.publicKey,
    if (c.presharedKey.isNotEmpty) 'pre_shared_key': c.presharedKey,
    'local_address': c.addresses,
    if (c.mtu > 0) 'mtu': c.mtu,
    if (c.reserved != null) 'reserved': c.reserved,
  },
  _ => throw UnsupportedError('${proxy.protocolLabel} не поддерживается'),
};

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
  AndroidSingboxHelper? _androidSb;

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

  Future<void> start(ParsedProxy proxy, {ConnectionMode mode = ConnectionMode.tunnel}) async {
    if (_isMobile) {
      if (_xraySupports(proxy)) {
        final config = const XrayConfigGenerator().generate(proxy);
        await _v2ray!.startV2Ray(
          remark: proxy.displayName,
          config: config,
          notificationDisconnectButtonName: 'Disconnect',
        );
      } else {
        // Chain proxy: sing-box handles the protocol, xray handles TUN routing
        _androidSb ??= AndroidSingboxHelper();
        try {
          await _androidSb!.start(_buildAndroidChainConfig(proxy));
          await Future.delayed(const Duration(milliseconds: 800));
          final passthroughConfig = const XrayConfigGenerator()
              .generateSocksPassthrough(AndroidSingboxHelper.chainProxyPort);
          await _v2ray!.startV2Ray(
            remark: proxy.displayName,
            config: passthroughConfig,
            notificationDisconnectButtonName: 'Disconnect',
          );
        } catch (e) {
          await _androidSb?.stop();
          _androidSb = null;
          rethrow;
        }
      }
    } else {
      await _windows!.start(proxy, mode: mode);
    }
  }

  Future<void> stop() async {
    if (_isMobile) {
      await _androidSb?.stop();
      _androidSb = null;
      await _v2ray!.stopV2Ray();
    } else {
      await _windows!.stop();
    }
  }

  Future<int> ping(ParsedProxy proxy) async {
    if (_isMobile) {
      if (_xraySupports(proxy)) {
        try {
          final config = const XrayConfigGenerator().generate(proxy);
          return _v2ray!.getServerDelay(config: config);
        } catch (_) {
          return -1;
        }
      }
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
    _statsController.close();
    _androidSb?.stop();
    _windows?.dispose();
  }
}

typedef SingboxDatasource = VpnDatasource;
