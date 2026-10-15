import '../../../servers/data/models/server_profile_model.dart';

enum ConnectionStatus {
  disconnected,
  preparing,
  connecting,
  connected,
  disconnecting,
  error,
}

class VpnStats {
  final double uploadSpeed; // bytes/s
  final double downloadSpeed; // bytes/s
  final int totalUpload; // bytes
  final int totalDownload; // bytes
  final Duration sessionDuration;
  final bool trafficAvailable;
  final bool ratesAvailable;

  const VpnStats({
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.totalUpload = 0,
    this.totalDownload = 0,
    this.sessionDuration = Duration.zero,
    this.trafficAvailable = true,
    this.ratesAvailable = true,
  });

  static const zero = VpnStats(trafficAvailable: false, ratesAvailable: false);
}

class NexConnectionState {
  final ConnectionStatus status;
  final ServerProfileModel? activeServer;
  final String? errorMessage;
  final VpnStats stats;

  /// Native identity may be known while its saved profile is absent/loading.
  /// In that case [activeServer] stays null rather than borrowing selection.
  final bool usesNativeSessionIdentity;
  final int? nativeProfileId;
  final String? nativeSessionId;

  const NexConnectionState({
    required this.status,
    this.activeServer,
    this.errorMessage,
    this.stats = VpnStats.zero,
    this.usesNativeSessionIdentity = false,
    this.nativeProfileId,
    this.nativeSessionId,
  });

  factory NexConnectionState.initial() =>
      const NexConnectionState(status: ConnectionStatus.disconnected);

  // Sentinel used by copyWith to distinguish "not provided" from explicit null,
  // allowing callers to clear activeServer / errorMessage back to null.
  static const Object _kAbsent = Object();

  NexConnectionState copyWith({
    ConnectionStatus? status,
    Object? activeServer = _kAbsent,
    Object? errorMessage = _kAbsent,
    VpnStats? stats,
    bool? usesNativeSessionIdentity,
    Object? nativeProfileId = _kAbsent,
    Object? nativeSessionId = _kAbsent,
  }) => NexConnectionState(
    status: status ?? this.status,
    activeServer: identical(activeServer, _kAbsent)
        ? this.activeServer
        : activeServer as ServerProfileModel?,
    errorMessage: identical(errorMessage, _kAbsent)
        ? this.errorMessage
        : errorMessage as String?,
    stats: stats ?? this.stats,
    usesNativeSessionIdentity:
        usesNativeSessionIdentity ?? this.usesNativeSessionIdentity,
    nativeProfileId: identical(nativeProfileId, _kAbsent)
        ? this.nativeProfileId
        : nativeProfileId as int?,
    nativeSessionId: identical(nativeSessionId, _kAbsent)
        ? this.nativeSessionId
        : nativeSessionId as String?,
  );

  bool get isConnected => status == ConnectionStatus.connected;
  bool get isBusy =>
      status == ConnectionStatus.connecting ||
      status == ConnectionStatus.preparing ||
      status == ConnectionStatus.disconnecting;
}
