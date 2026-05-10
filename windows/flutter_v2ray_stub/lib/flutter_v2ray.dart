library flutter_v2ray;

class V2RayStatus {
  final String state;
  final String duration;
  final String speed;
  const V2RayStatus({this.state = '', this.duration = '', this.speed = ''});
}

class FlutterV2ray {
  final void Function(V2RayStatus)? onStatusChanged;
  FlutterV2ray({this.onStatusChanged});

  Future<void> startV2Ray({
    String? remark,
    String? config,
    List<String>? blockedApps,
    List<String>? bypassSubnets,
    String? proxyOnly,
  }) async {}

  Future<void> stopV2Ray() async {}

  Future<bool> requestPermission() async => true;

  Future<String?> getServerDelay({required String config}) async => null;
}
