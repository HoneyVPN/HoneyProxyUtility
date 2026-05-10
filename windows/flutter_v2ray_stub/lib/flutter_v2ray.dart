library flutter_v2ray;

class V2RayStatus {
  final String state;
  final String duration;
  final int uploadSpeed;
  final int downloadSpeed;
  final int upload;
  final int download;
  const V2RayStatus({
    this.state = '',
    this.duration = '',
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.upload = 0,
    this.download = 0,
  });
}

class FlutterV2ray {
  final void Function(V2RayStatus)? onStatusChanged;
  FlutterV2ray({this.onStatusChanged});

  Future<void> initializeV2Ray({
    String? notificationIconResourceType,
    String? notificationIconResourceName,
  }) async {}

  Future<void> startV2Ray({
    String? remark,
    String? config,
    List<String>? blockedApps,
    List<String>? bypassSubnets,
    String? proxyOnly,
    String? notificationDisconnectButtonName,
  }) async {}

  Future<void> stopV2Ray() async {}

  Future<bool> requestPermission() async => true;

  Future<int> getServerDelay({required String config}) async => -1;
}
