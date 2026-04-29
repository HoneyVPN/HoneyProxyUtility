library flutter_v2ray;

class V2RayStatus {
  final String state;
  final double uploadSpeed;
  final double downloadSpeed;
  final int upload;
  final int download;
  final String duration;

  const V2RayStatus({
    this.state = 'DISCONNECTED',
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.upload = 0,
    this.download = 0,
    this.duration = '00:00:00',
  });
}

class FlutterV2ray {
  final void Function(V2RayStatus) onStatusChanged;
  FlutterV2ray({required this.onStatusChanged});

  Future<void> initializeV2Ray({
    String? notificationIconResourceType,
    String? notificationIconResourceName,
  }) async {}

  Future<bool> requestPermission() async => true;

  Future<void> startV2Ray({
    required String remark,
    required String config,
    String? notificationDisconnectButtonName,
  }) async {
    throw UnsupportedError('VPN not supported on this platform');
  }

  Future<void> stopV2Ray() async {}

  Future<int> getServerDelay({required String config}) async => -1;
}
