import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:logging/logging.dart';

import '../../data/datasources/singbox_datasource.dart';
import '../../domain/entities/connection_state.dart';
import '../../../converter/data/parsers/link_dispatcher.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../servers/data/models/server_profile_model.dart';
import '../../../settings/presentation/notifiers/settings_notifier.dart';
import '../../../settings/data/models/app_settings.dart';

final _log = Logger('ConnectionNotifier');

final connectionNotifierProvider =
    NotifierProvider<ConnectionNotifier, NexConnectionState>(
  ConnectionNotifier.new,
);

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

      try {
        _datasource ??= VpnDatasource(
          onStatusChanged: _onV2RayStatus,
          onError: (msg) {
            state = state.copyWith(
              status: ConnectionStatus.error,
              errorMessage: msg,
            );
          },
        );
        await _datasource!.initialize();
      } catch (e) {
        _datasource = null;
        rethrow;
      }

      final granted = await _datasource!.requestPermission();
      if (!granted) {
        state = state.copyWith(
          status: ConnectionStatus.disconnected,
          errorMessage: 'VPN permission denied',
        );
        return;
      }

      final settings = ref.read(settingsProvider).value ?? const AppSettings();
      final mode     = settings.connectionMode;

      state = state.copyWith(status: ConnectionStatus.connecting);
      await _datasource!.start(proxy, mode: mode, settings: settings);
    } catch (e) {
      _log.severe('Connection failed', e);
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> disconnect() async {
    if (!state.isConnected && !state.isBusy) return;
    state = state.copyWith(status: ConnectionStatus.disconnecting);
    try {
      await _datasource?.stop();
    } catch (e) {
      _log.warning('Error during disconnect', e);
    }
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
      // Do not override an error state — the error message must remain visible
      if (state.status != ConnectionStatus.error) {
        state = NexConnectionState.initial();
      }
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
    } catch (e) {
      _log.warning('Failed to deserialize proxy config', e);
    }
    return null;
  }

  static Duration _parseDuration(String s) {
    final parts = s.split(':').map(int.tryParse).toList();
    if (parts.length == 3 && parts.every((p) => p != null)) {
      return Duration(hours: parts[0]!, minutes: parts[1]!, seconds: parts[2]!);
    }
    return Duration.zero;
  }
}
