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

  NexConnectionState copyWith({
    ConnectionStatus? status,
    ServerProfileModel? activeServer,
    String? errorMessage,
    VpnStats? stats,
  }) => NexConnectionState(
    status: status ?? this.status,
    activeServer: activeServer ?? this.activeServer,
    errorMessage: errorMessage ?? this.errorMessage,
    stats: stats ?? this.stats,
  );

  bool get isConnected => status == ConnectionStatus.connected;
  bool get isBusy =>
    status == ConnectionStatus.connecting ||
    status == ConnectionStatus.preparing ||
    status == ConnectionStatus.disconnecting;
}
