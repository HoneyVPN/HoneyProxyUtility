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
  final double uploadSpeed;   // bytes/s
  final double downloadSpeed; // bytes/s
  final int totalUpload;      // bytes
  final int totalDownload;    // bytes
  final Duration sessionDuration;

  const VpnStats({
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.totalUpload = 0,
    this.totalDownload = 0,
    this.sessionDuration = Duration.zero,
  });

  static const zero = VpnStats();
}

class NexConnectionState {
  final ConnectionStatus status;
  final ServerProfileModel? activeServer;
  final String? errorMessage;
  final VpnStats stats;

  const NexConnectionState({
    required this.status,
    this.activeServer,
    this.errorMessage,
    this.stats = VpnStats.zero,
  });

  factory NexConnectionState.initial() => const NexConnectionState(
    status: ConnectionStatus.disconnected,
  );

  // Sentinel used by copyWith to distinguish "not provided" from explicit null,
  // allowing callers to clear activeServer / errorMessage back to null.
  static const Object _kAbsent = Object();

  NexConnectionState copyWith({
    ConnectionStatus? status,
    Object? activeServer = _kAbsent,
    Object? errorMessage = _kAbsent,
    VpnStats? stats,
  }) => NexConnectionState(
    status: status ?? this.status,
    activeServer: identical(activeServer, _kAbsent)
        ? this.activeServer
        : activeServer as ServerProfileModel?,
    errorMessage: identical(errorMessage, _kAbsent)
        ? this.errorMessage
        : errorMessage as String?,
    stats: stats ?? this.stats,
  );

  bool get isConnected => status == ConnectionStatus.connected;
  bool get isBusy =>
    status == ConnectionStatus.connecting ||
    status == ConnectionStatus.preparing ||
    status == ConnectionStatus.disconnecting;
}
