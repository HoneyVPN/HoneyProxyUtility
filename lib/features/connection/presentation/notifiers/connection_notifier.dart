import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/vpn_core_status.dart';
import 'package:logging/logging.dart';

import '../../data/datasources/singbox_datasource.dart';
import '../../data/datasources/apple_vpn_datasource.dart';
import '../../data/singbox/provider_geo_bundle.dart';
import '../../data/singbox/provider_geo_runtime.dart';
import '../../data/windows/windows_session.dart';
import '../../../settings/data/models/app_settings.dart';
import '../../domain/entities/connection_state.dart';
import '../../../converter/data/parsers/link_dispatcher.dart';
import '../../../converter/data/parsers/base_parser.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../servers/data/models/server_profile_model.dart';
import '../../../servers/presentation/notifiers/servers_notifier.dart';
import '../../../subscriptions/data/models/subscription_model.dart';
import '../../../subscriptions/data/services/subscription_policy.dart';
import '../../../subscriptions/data/services/subscriptions_notifier.dart';
import '../../../subscriptions/domain/entities/provider_geo_state.dart';
import '../../../settings/presentation/notifiers/settings_notifier.dart';
import '../../../settings/data/log_provider.dart';
import '../../../../app/l10n/strings.dart';

final _log = Logger('ConnectionNotifier');

typedef VpnDatasourceFactory =
    VpnDatasource Function({
      required void Function(VpnCoreStatus) onStatusChanged,
      void Function(String)? onError,
    });

final vpnDatasourceFactoryProvider = Provider<VpnDatasourceFactory>(
  (ref) =>
      ({
        required void Function(VpnCoreStatus) onStatusChanged,
        void Function(String)? onError,
      }) => VpnDatasource(onStatusChanged: onStatusChanged, onError: onError),
);

final connectionNotifierProvider =
    NotifierProvider<ConnectionNotifier, NexConnectionState>(
      ConnectionNotifier.new,
    );

class ConnectionNotifier extends Notifier<NexConnectionState> {
  VpnDatasource? _datasource;
  Future<void>? _pendingStart;
  Future<void> _pendingCleanup = Future<void>.value();
  int _generation = 0;
  int _nativeIdentityRevision = 0;
  Future<void>? _startupDiscovery;
  bool _discoveryPending = false;
  bool _requiresNativeDiscovery = false;
  bool _nativeDiscoveryConfirmed = false;
  String? _lastDiscoveryState;
  WindowsSessionFailure? _startupWindowsFailure;
  bool _managedVpnSession = false;
  bool _shutdownInProgress = false;
  bool _exitAuthorized = false;
  Future<void>? _pendingDisconnect;
  Map<String, String>? _localizedErrorMessages;

  @override
  NexConnectionState build() {
    ref.listen<S>(stringsProvider, (_, strings) {
      final messages = _localizedErrorMessages;
      if (!ref.mounted ||
          messages == null ||
          state.errorMessage == null ||
          !messages.values.contains(state.errorMessage)) {
        return;
      }
      final translated = messages[strings.locale];
      if (translated != null && translated != state.errorMessage) {
        // Presentation only: do not restart discovery or change VPN ownership.
        state = state.copyWith(errorMessage: translated);
      }
    });
    ref.onDispose(() {
      _generation++;
      final source = _datasource;
      final start = _pendingStart;
      _datasource = null;
      _pendingStart = null;
      if (start != null) {
        unawaited(
          _queueStop(source, start).catchError((
            Object error,
            StackTrace stack,
          ) {
            _log.warning(
              'Cleanup failed after provider disposal',
              error,
              stack,
            );
            // There is no live owner left to retry; detach callbacks, while the
            // OS-managed tunnel remains discoverable on the next app launch.
            source?.dispose();
          }),
        );
      } else {
        source?.dispose();
      }
    });
    _startupDiscovery = _restoreIfRunning();
    return NexConnectionState.initial();
  }

  /// On app launch, checks whether the native VPN service is already running
  /// (e.g. the user closed and reopened the app while connected). If so,
  /// re-attaches the stats listener and marks the state as connected so the
  /// UI immediately reflects the real situation.
  Future<void> _restoreIfRunning() async {
    final generation = _generation;
    _discoveryPending = true;
    if (_isCurrent(generation)) _startupWindowsFailure = null;
    VpnDatasource? probe;
    try {
      probe = _newSource(generation);
      _requiresNativeDiscovery = probe.requiresNativeSessionDiscovery;
      if (_requiresNativeDiscovery) _nativeDiscoveryConfirmed = false;
      final snapshot = await probe.readCurrentStatus();
      if (_isCurrent(generation)) {
        _lastDiscoveryState = snapshot?.state;
      }
      if (_isCurrent(generation) && _requiresNativeDiscovery) {
        _nativeDiscoveryConfirmed =
            snapshot != null &&
            [
              'CONNECTED',
              'CONNECTING',
              'DISCONNECTING',
              'DISCONNECTED',
            ].contains(snapshot.state);
      }
      // Guard: if connect() was called while we awaited the platform channel,
      // _datasource is already set — don't overwrite it with the probe.
      if (!_isCurrent(generation) ||
          snapshot == null ||
          ![
            'CONNECTED',
            'CONNECTING',
            'DISCONNECTING',
          ].contains(snapshot.state) ||
          _datasource != null) {
        probe.dispose();
        return;
      }
      _datasource = probe;
      _managedVpnSession = true;
      state = NexConnectionState(
        status: ConnectionStatus.connecting,
        activeServer: snapshot.usesNativeSessionIdentity
            ? null
            : ref.read(selectedServerProvider),
      );
      _onCoreStatus(snapshot);
      _datasource!.reattach();
    } catch (e) {
      probe?.dispose();
      _log.warning('Failed to restore VPN state on startup', e);
      if (_isCurrent(generation) && e is WindowsSessionException) {
        _startupWindowsFailure = e.failure;
        state = state.copyWith(
          status: ConnectionStatus.error,
          errorMessage: _localizedMessage(
            (strings) =>
                _windowsMessage(e.code, strings) ?? strings.vpnUnknownFailure,
          ),
        );
      }
    } finally {
      _discoveryPending = false;
      if (_isCurrent(generation)) {
        // Also notify when a native idle snapshot leaves the visible status
        // unchanged: tray readiness must not be inferred from initial state.
        state = state.copyWith();
      }
    }
  }

  bool get isTrayReady =>
      !_discoveryPending &&
      (_datasource != null ||
          const {
            'CONNECTED',
            'CONNECTING',
            'DISCONNECTING',
            'DISCONNECTED',
          }.contains(_lastDiscoveryState));

  /// A native menu must await the startup snapshot before it interprets
  /// toggle/selection/mode actions against the initially disconnected UI.
  Future<bool> prepareTrayAction() async {
    await _startupDiscovery;
    if (!ref.mounted || _shutdownInProgress) return false;
    if (!isTrayReady) {
      _lastDiscoveryState = null;
      _startupDiscovery = _restoreIfRunning();
      await _startupDiscovery;
    }
    return ref.mounted && !_shutdownInProgress && isTrayReady;
  }

  Future<void> connect(ServerProfileModel server) async {
    if (!ref.mounted || state.isBusy || _shutdownInProgress) return;
    if (_requiresNativeDiscovery) {
      final discoveryGeneration = _generation;
      final wasPending = _discoveryPending;
      await _startupDiscovery;
      if (!_isCurrent(discoveryGeneration) || state.isBusy) return;
      if (!_nativeDiscoveryConfirmed && !wasPending) {
        // An unknown snapshot is not proof that no OS-owned tunnel exists.
        // Retry read-only discovery, never stop an unowned session as cleanup
        // for a failed start request.
        _startupDiscovery = _restoreIfRunning();
        await _startupDiscovery;
        if (!_isCurrent(discoveryGeneration) || state.isBusy) return;
      }
      if (!_nativeDiscoveryConfirmed) {
        state = state.copyWith(
          status: ConnectionStatus.error,
          errorMessage: _localizedMessage(
            (strings) => strings.appleVpnConnectFailed,
          ),
        );
        return;
      }
    }
    final generation = ++_generation;
    final previous = _datasource;
    final previousStart = _pendingStart;
    final previousState = state;
    _datasource = null;
    _pendingStart = null;
    VpnDatasource? source;
    ParsedProxy? proxy;

    ref
        .read(logProvider.notifier)
        .add(
          ref
              .read(stringsProvider)
              .connectionLogConnecting(
                server.name.isNotEmpty ? server.name : server.host,
                server.protocol.toUpperCase(),
              ),
        );
    state = state.copyWith(
      status: ConnectionStatus.preparing,
      activeServer: server,
      errorMessage: null,
      stats: VpnStats.zero,
      usesNativeSessionIdentity: false,
      nativeProfileId: null,
      nativeSessionId: null,
    );

    try {
      await _queueStop(previous, previousStart);
    } catch (_) {
      if (!_isCurrent(generation)) {
        previous?.dispose();
        return;
      }
      // The previous tunnel may still own system routing. Retain its source
      // and retry cleanup before allowing a new session to be created.
      _datasource = previous;
      _pendingStart = previousStart;
      _generation++;
      state = previousState.copyWith(
        status: ConnectionStatus.error,
        errorMessage: _localizedMessage((strings) => strings.vpnStopFailed),
      );
      _resolveRetainedNativeProfile();
      return;
    }
    if (!_isCurrent(generation)) return;

    try {
      // Load the saved locale before an early parser/compatibility failure.
      final settings = await ref.read(settingsProvider.future);
      if (!_isCurrent(generation)) return;
      settings.validateNetworkSettings(
        validateProxyPorts:
            !(!kIsWeb &&
                Platform.isWindows &&
                settings.connectionMode == ConnectionMode.tunnel),
      );
      proxy = _deserializeProxy(server.configJson);
      if (proxy == null) {
        throw Exception('Cannot parse server config');
      }
      if (!kIsWeb &&
          (Platform.isMacOS || Platform.isIOS) &&
          settings.connectionMode != ConnectionMode.tunnel) {
        throw const AppleVpnException(AppleVpnFailure.proxyMode);
      }

      if (proxy is NaiveConfig ||
          (!kIsWeb && Platform.isWindows && proxy is ShadowTlsConfig)) {
        throw UnsupportedError(proxy.protocolLabel);
      }

      ProviderGeoBundle? providerRouting;
      if (settings.routingMode != RoutingMode.global &&
          settings.geoRoutingMode != GeoRoutingMode.builtIn) {
        final url = normalizeSubscriptionUrl(server.subscriptionId);
        SubscriptionModel? subscription;
        if (url.isNotEmpty) {
          final subscriptions = await ref.read(subscriptionsProvider.future);
          if (!_isCurrent(generation)) return;
          for (final item in subscriptions.subs) {
            if (normalizeSubscriptionUrl(item.url) == url) {
              subscription = item;
              break;
            }
          }
        }
        providerRouting = await ref
            .read(providerGeoRuntimeProvider)
            .resolveForSubscription(subscription, settings);
        if (!_isCurrent(generation)) return;
      }

      source = _newSource(generation);
      _datasource = source;
      source.bindProfile(server.id);
      source.bindProviderRouting(providerRouting);
      await source.initialize();
      if (!_isCurrent(generation)) return;

      final granted = await source.requestPermission();
      if (!_isCurrent(generation)) return;
      if (!granted) {
        _datasource = null;
        source.dispose();
        state = state.copyWith(
          status: ConnectionStatus.disconnected,
          errorMessage: _localizedMessage(
            (strings) => strings.vpnPermissionDenied,
          ),
        );
        return;
      }

      final mode = settings.connectionMode;

      state = state.copyWith(status: ConnectionStatus.connecting);
      _managedVpnSession = true;
      final start = source.start(proxy, mode: mode, settings: settings);
      _pendingStart = start;
      await start;
      if (_isCurrent(generation)) _pendingStart = null;
    } catch (e, stack) {
      if (!_isCurrent(generation)) return;
      final start = _pendingStart;
      _datasource = null;
      _pendingStart = null;
      try {
        if (start == null) {
          // Readiness/permission failures did not submit a new VPN start. Do
          // not replace their useful error with a stop call to a missing bridge.
          source?.dispose();
        } else {
          await _queueStop(source, start);
        }
      } catch (_) {
        if (!_isCurrent(generation)) {
          source?.dispose();
          return;
        }
        _datasource = source;
        _pendingStart = start;
        _generation++;
        state = state.copyWith(
          status: ConnectionStatus.error,
          errorMessage: _localizedMessage((strings) => strings.vpnStopFailed),
        );
        _resolveRetainedNativeProfile();
        return;
      }
      if (!_isCurrent(generation)) return;
      _log.severe('Connection failed', e, stack);
      _generation++;
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: _localizedMessage(
          (strings) => e is SettingsValidationException
              ? _settingsMessage(e.issue, strings)
              : e is ProviderGeoException
              ? strings.providerGeoFailure(e.issue)
              : e is WindowsSessionException
              ? _windowsMessage(e.code, strings) ?? strings.vpnUnknownFailure
              : e is AppleVpnException
              ? (e.failure == AppleVpnFailure.proxyMode
                    ? strings.appleProxyUnavailable
                    : strings.appleVpnUnavailable)
              : e is UnsupportedError && e.message == 'platform'
              ? strings.unsupportedPlatform
              : e is UnsupportedError &&
                    (proxy is NaiveConfig ||
                        (!kIsWeb &&
                            Platform.isWindows &&
                            proxy is ShadowTlsConfig))
              ? strings.protocolUnavailable(
                  proxy is NaiveConfig ? 'NaiveProxy' : proxy!.protocolLabel,
                )
              : e is UnsupportedConfigurationException || e is UnsupportedError
              ? strings.serverOptionsUnavailable
              : strings.nativeVpnError(
                  e is PlatformException ? (e.message ?? '') : '',
                ),
        ),
      );
    }
  }

  Future<void> disconnect() async {
    if (!ref.mounted) return;
    if (state.status == ConnectionStatus.disconnecting) return;
    final completion = Completer<void>();
    final completed = completion.future;
    _pendingDisconnect = completed;
    try {
      // Invalidate restoration/permission/start callbacks before awaiting cleanup.
      final generation = ++_generation;
      final source = _datasource;
      final start = _pendingStart;
      _datasource = null;
      _pendingStart = null;
      state = state.copyWith(status: ConnectionStatus.disconnecting);
      try {
        await _queueStop(source, start);
      } catch (_) {
        if (!_isCurrent(generation)) {
          source?.dispose();
          return;
        }
        _datasource = source;
        _pendingStart = start;
        _generation++;
        state = state.copyWith(
          status: ConnectionStatus.error,
          errorMessage: _localizedMessage((strings) => strings.vpnStopFailed),
        );
        _resolveRetainedNativeProfile();
        return;
      }
      if (_isCurrent(generation)) state = NexConnectionState.initial();
    } finally {
      completion.complete();
      if (identical(_pendingDisconnect, completed)) _pendingDisconnect = null;
    }
  }

  /// Own VPN sessions require confirmed cleanup before exit. A new window
  /// which failed Windows discovery before managing any VPN may close its UI
  /// without claiming or modifying the older, undiscovered session.
  Future<bool> shutdownForExit() async {
    if (!ref.mounted || _shutdownInProgress) return false;
    _shutdownInProgress = true;
    try {
      await _startupDiscovery;
      if (!ref.mounted) return false;
      if (_startupWindowsFailure != null &&
          !_managedVpnSession &&
          _datasource == null &&
          _pendingStart == null &&
          _pendingDisconnect == null &&
          state.status == ConnectionStatus.error) {
        _exitAuthorized = true;
        return true;
      }
      await disconnect();
      // A second disconnect call can arrive while the first native stop is
      // still pending; its early return is not the stop acknowledgement.
      await _pendingDisconnect;
      if (!ref.mounted || state.status != ConnectionStatus.disconnected) {
        return false;
      }
      final generation = _generation;
      _lastDiscoveryState = null;
      _startupDiscovery = _restoreIfRunning();
      await _startupDiscovery;
      if (!_isCurrent(generation) ||
          state.status != ConnectionStatus.disconnected) {
        return false;
      }
      if (_lastDiscoveryState != 'DISCONNECTED') {
        state = state.copyWith(
          status: ConnectionStatus.error,
          errorMessage: _localizedMessage((strings) => strings.vpnStopFailed),
        );
        return false;
      }
      _exitAuthorized = true;
      return true;
    } finally {
      // Keep Home actions blocked between authorization and native window
      // destruction. A rejected native quit explicitly releases this gate.
      if (!_exitAuthorized) _shutdownInProgress = false;
    }
  }

  void cancelExitAuthorization() {
    if (!ref.mounted || !_exitAuthorized) return;
    _exitAuthorized = false;
    _shutdownInProgress = false;
  }

  bool _isCurrent(int generation) => ref.mounted && generation == _generation;

  VpnDatasource _newSource(int generation) =>
      ref.read(vpnDatasourceFactoryProvider)(
        onStatusChanged: (status) {
          if (_isCurrent(generation)) _onCoreStatus(status);
        },
        onError: (message) {
          if (!_isCurrent(generation)) return;
          final visibleMessage = _localizedMessage(
            (strings) => message == AppleVpnDatasource.connectionFailedMessage
                ? strings.appleVpnConnectFailed
                : message == VpnDatasource.nativeStatusUnavailableMessage
                ? strings.vpnStatusUnavailable
                : _windowsMessage(message, strings) ??
                      strings.nativeVpnError(message),
          );
          ref.read(logProvider.notifier).add(visibleMessage, isError: true);
          state = state.copyWith(
            status: ConnectionStatus.error,
            errorMessage: visibleMessage,
          );
          // Further queued stats from this failed session must not revive it.
          _generation++;
        },
      );

  String _localizedMessage(String Function(S) translate) {
    // Store only safe translated copy, never the native exception or payload.
    final messages = {'ru': translate(S('ru')), 'en': translate(S('en'))};
    _localizedErrorMessages = messages;
    return messages[ref.read(stringsProvider).locale] ?? messages['en']!;
  }

  String? _windowsMessage(String code, S strings) =>
      WindowsSessionException.messageFor(code, strings.locale);

  String _settingsMessage(SettingsValidationIssue issue, S strings) {
    return switch (issue) {
      SettingsValidationIssue.ports => strings.invalidPorts,
      SettingsValidationIssue.dnsAddress => strings.invalidDnsAddress,
      SettingsValidationIssue.dnsPort => strings.customDnsPortUnsupported,
      SettingsValidationIssue.dnsExtras => strings.customDnsExtrasUnsupported,
      SettingsValidationIssue.dnsTlsPath => strings.customDnsTlsPathUnsupported,
    };
  }

  Future<void> _stopSource(VpnDatasource? source, Future<void>? start) async {
    if (source == null) return;
    if (start != null) {
      try {
        await start;
      } catch (_) {}
    }
    try {
      await source.stop();
    } catch (e, stack) {
      _log.warning('Error during disconnect', e, stack);
      rethrow;
    }
    source.dispose();
  }

  Future<void> _queueStop(VpnDatasource? source, Future<void>? start) {
    if (source == null) return _pendingCleanup;
    final operation = _pendingCleanup.then((_) => _stopSource(source, start));
    _pendingCleanup = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  void _onCoreStatus(VpnCoreStatus status) {
    final vpnState = status.state.toUpperCase();
    if (vpnState == 'CONNECTED' && state.status != ConnectionStatus.connected) {
      ref
          .read(logProvider.notifier)
          .add(
            ref
                .read(stringsProvider)
                .connectionLogConnected(
                  state.activeServer?.name ??
                      state.activeServer?.host ??
                      ref.read(stringsProvider).genericServer,
                ),
          );
    } else if (vpnState == 'DISCONNECTED' &&
        state.status == ConnectionStatus.connected) {
      ref
          .read(logProvider.notifier)
          .add(ref.read(stringsProvider).connectionLogDisconnected);
    }
    if (vpnState == 'CONNECTED') {
      state = state.copyWith(
        status: ConnectionStatus.connected,
        stats: VpnStats(
          uploadSpeed: status.uploadSpeed.toDouble(),
          downloadSpeed: status.downloadSpeed.toDouble(),
          totalUpload: status.upload,
          totalDownload: status.download,
          sessionDuration: _parseDuration(status.duration),
          trafficAvailable: status.trafficAvailable,
          ratesAvailable: status.ratesAvailable,
        ),
      );
    } else if (vpnState == 'DISCONNECTED') {
      // During an active server switch the old session's watchdog can post a
      // stale "stopped" event that races with the new connection being set up.
      // Ignore it — the new session will send its own "started" or "error".
      if (state.status == ConnectionStatus.preparing ||
          state.status == ConnectionStatus.connecting) {
        if (!status.usesNativeSessionIdentity) return;
      }
      // Do not override an error state — the error message must remain visible
      if (state.status != ConnectionStatus.error) {
        state = NexConnectionState.initial();
        _nativeIdentityRevision++;
        _generation++;
        if (status.usesNativeSessionIdentity && _pendingStart == null) {
          _datasource?.dispose();
          _datasource = null;
        }
      }
    } else if (vpnState == 'CONNECTING') {
      state = state.copyWith(status: ConnectionStatus.connecting);
    } else if (vpnState == 'DISCONNECTING') {
      state = state.copyWith(status: ConnectionStatus.disconnecting);
    }
    if (status.usesNativeSessionIdentity && vpnState != 'DISCONNECTED') {
      _applyNativeIdentity(status);
    }
  }

  void _applyNativeIdentity(VpnCoreStatus status) {
    if (state.usesNativeSessionIdentity &&
        state.nativeProfileId == status.profileId &&
        state.nativeSessionId == status.sessionId)
      return;
    final generation = _generation;
    final revision = ++_nativeIdentityRevision;
    final profileId = status.profileId;
    final current = state.activeServer;
    final matching = profileId != null && current?.id == profileId
        ? current
        : null;
    state = state.copyWith(
      usesNativeSessionIdentity: true,
      nativeProfileId: profileId,
      nativeSessionId: status.sessionId,
      activeServer: matching,
    );
    if (profileId == null || matching != null) return;
    unawaited(
      _resolveNativeProfile(profileId, status.sessionId, generation, revision),
    );
  }

  Future<void> _resolveNativeProfile(
    int profileId,
    String? sessionId,
    int generation,
    int revision,
  ) async {
    try {
      final profiles = await ref.read(serversNotifierProvider.future);
      if (!_isCurrent(generation) ||
          revision != _nativeIdentityRevision ||
          state.nativeProfileId != profileId ||
          state.nativeSessionId != sessionId)
        return;
      final match = profiles
          .where((profile) => profile.id == profileId)
          .firstOrNull;
      state = state.copyWith(activeServer: match);
    } catch (error) {
      // Native connected state is still authoritative when saved profiles fail
      // to load. Do not label that session with whichever profile is selected.
      _log.warning('Could not resolve the active native VPN profile', error);
    }
  }

  void _resolveRetainedNativeProfile() {
    final profileId = state.nativeProfileId;
    if (!state.usesNativeSessionIdentity ||
        profileId == null ||
        state.activeServer != null)
      return;
    unawaited(
      _resolveNativeProfile(
        profileId,
        state.nativeSessionId,
        _generation,
        ++_nativeIdentityRevision,
      ),
    );
  }

  ParsedProxy? _deserializeProxy(String configJson) {
    try {
      final map = json.decode(configJson) as Map<String, dynamic>;
      final rawLink = map['rawLink'] as String?;
      if (rawLink != null && rawLink.isNotEmpty) {
        return const LinkDispatcher().dispatch(rawLink);
      }
    } on UnsupportedConfigurationException {
      rethrow;
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
