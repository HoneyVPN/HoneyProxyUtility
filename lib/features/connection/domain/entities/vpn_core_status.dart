/// Status and byte counters emitted by the native VPN core.
class VpnCoreStatus {
  final String state;
  final String duration;
  final int uploadSpeed;
  final int downloadSpeed;
  final int upload;
  final int download;
  final bool trafficAvailable;
  final bool ratesAvailable;

  /// Apple native status is authoritative even when a legacy/deleted profile
  /// cannot be resolved locally. Other platform status producers stay compatible.
  final bool usesNativeSessionIdentity;
  final int? profileId;
  final String? sessionId;

  const VpnCoreStatus({
    this.state = 'DISCONNECTED',
    this.duration = '00:00:00',
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.upload = 0,
    this.download = 0,
    this.trafficAvailable = true,
    this.ratesAvailable = true,
    this.usesNativeSessionIdentity = false,
    this.profileId,
    this.sessionId,
  });
}
