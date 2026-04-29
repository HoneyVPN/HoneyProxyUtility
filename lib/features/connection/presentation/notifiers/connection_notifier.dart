import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';

import '../../data/datasources/singbox_datasource.dart';
import '../../domain/entities/connection_state.dart';
import '../../../converter/data/parsers/link_dispatcher.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../servers/data/models/server_profile_model.dart';

final connectionNotifierProvider =
    NotifierProvider<ConnectionNotifier, NexConnectionState>(
  ConnectionNotifier.new,
);

final appSettingsProvider = Provider((_) => const AppSettings());

class ConnectionNotifier extends Notifier<NexConnectionState> {
  VpnDatasource? _datasource;

  @override
  NexConnectionState build() {
    ref.onDispose(() => _datasource?.dispose());
    return NexConnectionState.initial();
  }

  Future<void> connect(ServerProfileModel server) async {
    if (state.isBusy) return;

    state = state.copyWith(
      status: ConnectionStatus.preparing,
      activeServer: server,
      errorMessage: null,
    );

    try {
      final proxy = _deserializeProxy(server.configJson);
      if (proxy == null) {
        throw Exception('Cannot parse server config');
      }

      // Lazy init datasource with status callback wired to our state
      _datasource ??= VpnDatasource(onStatusChanged: _onV2RayStatus);
      await _datasource!.initialize();

      final granted = await _datasource!.requestPermission();
      if (!granted) {
        state = state.copyWith(
          status: ConnectionStatus.disconnected,
          errorMessage: 'VPN permission denied',
        );
        return;
      }

      state = state.copyWith(status: ConnectionStatus.connecting);
      await _datasource!.start(proxy);
      // Status will update to connected via _onV2RayStatus callback
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: e is UnsupportedError ? (e.message ?? e.toString()) : e.toString(),
      );
    }
  }

  Future<void> disconnect() async {
    if (!state.isConnected && !state.isBusy) return;
    state = state.copyWith(status: ConnectionStatus.disconnecting);
    try {
      await _datasource?.stop();
    } catch (_) {}
    state = NexConnectionState.initial();
  }

  void _onV2RayStatus(V2RayStatus status) {
    final vpnState = status.state.toUpperCase();
    if (vpnState == 'CONNECTED') {
      state = state.copyWith(
        status: ConnectionStatus.connected,
        stats: VpnStats(
          uploadSpeed: status.uploadSpeed.toDouble(),
          downloadSpeed: status.downloadSpeed.toDouble(),
          totalUpload: status.upload,
          totalDownload: status.download,
          sessionDuration: _parseDuration(status.duration),
        ),
      );
    } else if (vpnState == 'DISCONNECTED') {
      state = NexConnectionState.initial();
    } else if (vpnState == 'CONNECTING') {
      state = state.copyWith(status: ConnectionStatus.connecting);
    }
  }

  ParsedProxy? _deserializeProxy(String configJson) {
    try {
      final map = json.decode(configJson) as Map<String, dynamic>;
      final rawLink = map['rawLink'] as String?;
      if (rawLink != null && rawLink.isNotEmpty) {
        return const LinkDispatcher().dispatch(rawLink);
      }
    } catch (_) {}
    return null;
  }

  static Duration _parseDuration(String s) {
    // Format: "HH:MM:SS"
    final parts = s.split(':').map(int.tryParse).toList();
    if (parts.length == 3 && parts.every((p) => p != null)) {
      return Duration(hours: parts[0]!, minutes: parts[1]!, seconds: parts[2]!);
    }
    return Duration.zero;
  }
}
