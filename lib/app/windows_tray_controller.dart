import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../features/connection/data/vpn_disclosure_provider.dart';
import '../features/connection/domain/entities/connection_state.dart';
import '../features/connection/presentation/notifiers/connection_notifier.dart';
import '../features/servers/data/models/server_profile_model.dart';
import '../features/servers/presentation/notifiers/servers_notifier.dart';
import '../features/servers/presentation/server_selection_groups.dart';
import '../features/settings/data/models/app_settings.dart';
import '../features/settings/presentation/notifiers/settings_notifier.dart';
import '../features/subscriptions/data/services/subscriptions_notifier.dart';
import '../features/servers/presentation/widgets/country_presentation.dart';
import 'l10n/strings.dart';

/// The tray receives presentation metadata only. VPN ownership and all saved
/// mutations remain in the same notifiers used by the application window.
class WindowsTrayController {
  WindowsTrayController({
    required ProviderContainer container,
    required void Function(String) navigate,
    required void Function(String) showError,
    MethodChannel channel = const MethodChannel('ru.honeyvpn.proxy/commands'),
    Future<ClipboardData?> Function()? readClipboard,
  }) : _container = container,
       _navigate = navigate,
       _showError = showError,
       _channel = channel,
       _readClipboard =
           readClipboard ?? (() => Clipboard.getData(Clipboard.kTextPlain));

  final ProviderContainer _container;
  final void Function(String) _navigate;
  final void Function(String) _showError;
  final MethodChannel _channel;
  final Future<ClipboardData?> Function() _readClipboard;
  final _closeListeners = <void Function()>[];
  bool _started = false;
  bool _disposed = false;
  bool _mutating = false;
  bool _quitting = false;
  bool _publishScheduled = false;
  int _generation = 0;
  int _importActivation = 0;
  String? _lastPublished;
  Future<void> _writes = Future<void>.value();
  final _bindingsById = <int, _TrayProfileBinding>{};
  final _bindingsByToken = <String, _TrayProfileBinding>{};
  static int _nextProfileToken = 0;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (_disposed || call.method != 'trayAction' || call.arguments is! Map) {
        return false;
      }
      return _action(call.arguments as Map);
    });
    _listen(connectionNotifierProvider);
    _listen(serversNotifierProvider);
    _listen(subscriptionsProvider);
    _listen(settingsProvider);
    _listen(vpnDisclosureProvider);
    _schedulePublish();
  }

  void _listen<T>(ProviderListenable<T> provider) {
    final subscription = _container.listen(
      provider,
      (_, __) => _schedulePublish(),
    );
    _closeListeners.add(subscription.close);
  }

  NexConnectionState get _connection =>
      _container.read(connectionNotifierProvider);
  bool get _busy => _mutating || _quitting || _connection.isBusy;
  bool get _ready =>
      _container.read(connectionNotifierProvider.notifier).isTrayReady;
  bool _current(int generation) =>
      !_disposed && !_quitting && generation == _generation;
  S get _strings => _container.read(stringsProvider);

  Map<String, Object?> _snapshot() {
    final settings = _container.read(settingsProvider).value;
    final selected = _container.read(selectedServerProvider);
    final subscriptions =
        _container.read(subscriptionsProvider).value?.subs ?? [];
    final subscriptionsByUrl = {for (final sub in subscriptions) sub.url: sub};
    final profiles = _container.read(serversNotifierProvider).value ?? [];
    _retireChangedBindings(profiles);
    final groups = serverSelectionGroups(profiles, subscriptions);
    final ordered = [for (final group in groups) ...group.servers];
    final groupForProfile = {
      for (final group in groups)
        for (final profile in group.servers) profile.id: group.subscriptionId,
    };
    final chosenIds = ordered.take(1024).map((profile) => profile.id).toSet();
    // Keep selection addressable at the limit without moving its group first.
    if (selected != null && !chosenIds.contains(selected.id)) {
      if (chosenIds.length == 1024) chosenIds.remove(ordered[1023].id);
      chosenIds.add(selected.id);
    }
    final chosen = ordered
        .where((profile) => chosenIds.remove(profile.id))
        .toList();
    if (selected != null && chosenIds.contains(selected.id))
      chosen.add(selected);
    final knownGroups = <String>{};
    final rows = <Map<String, String>>[];
    for (final profile in chosen) {
      final favoriteGroup = groupForProfile.containsKey(profile.id)
          ? groupForProfile[profile.id] == null
          : profile.isFavorite;
      final subscription = subscriptionsByUrl[profile.subscriptionId];
      var groupId = favoriteGroup
          ? 'favorites'
          : profile.subscriptionId.isEmpty
          ? 'manual'
          : subscription == null
          ? 'other'
          : 'subscription-${subscription.id}';
      var group = _label(
        favoriteGroup
            ? _strings.favoritesTitle
            : profile.subscriptionId.isEmpty
            ? _strings.manualGroup
            : subscription?.name ?? _strings.subscriptionsTooltip,
        256,
        _strings.subscriptionsTooltip,
      );
      if (!knownGroups.contains(groupId) && knownGroups.length >= 127) {
        groupId = 'other';
        group = _strings.subscriptionsTooltip;
      }
      knownGroups.add(groupId);
      final country = _serverPresentation(profile);
      rows.add({
        'id': _tokenFor(profile),
        'name': country.displayName,
        'group': group,
        'groupId': groupId,
        'countryCode': country.countryCode ?? '',
      });
    }
    return {
      'locale': settings?.locale == 'ru' ? 'ru' : 'en',
      'connected': _connection.isConnected,
      'busy': _busy || !_ready,
      'selectedId': selected == null ? null : _tokenFor(selected),
      'selectedName': selected == null ? null : _serverName(selected),
      'tunnel': settings?.connectionMode != ConnectionMode.proxy,
      'servers': rows,
      'canConnect':
          settings != null &&
          selected != null &&
          !_busy &&
          _ready &&
          (_container.read(vpnDisclosureProvider).value ?? false),
    };
  }

  CountryPresentation _serverPresentation(ServerProfileModel profile) {
    final fallback =
        '${_strings.locale == 'ru' ? 'Сервер' : 'Server'} ${profile.id}';
    return CountryPresentation.fromName(
      _label(profile.name, 512, fallback),
      fallbackName: fallback,
    );
  }

  String _serverName(ServerProfileModel profile) =>
      _serverPresentation(profile).displayName;

  String _tokenFor(ServerProfileModel profile) {
    final previous = _bindingsById[profile.id];
    if (previous != null && previous.matches(profile)) return previous.token;
    if (previous != null) _bindingsByToken.remove(previous.token);
    // A process-local monotonic token cannot be reused when storage reuses an
    // integer ID. No profile configuration or hash crosses the native channel.
    final binding = _TrayProfileBinding(
      'profile-${++_nextProfileToken}',
      profile,
    );
    _bindingsById[profile.id] = binding;
    _bindingsByToken[binding.token] = binding;
    return binding.token;
  }

  void _retireChangedBindings(List<ServerProfileModel> profiles) {
    final current = {for (final profile in profiles) profile.id: profile};
    _bindingsById.removeWhere((id, binding) {
      final profile = current[id];
      if (profile != null && binding.matches(profile)) return false;
      _bindingsByToken.remove(binding.token);
      return true;
    });
  }

  ServerProfileModel? _profileForToken(String token) {
    final binding = _bindingsByToken[token];
    if (binding == null) return null;
    final profile = (_container.read(serversNotifierProvider).value ?? [])
        .where((profile) => profile.id == binding.profile.id)
        .firstOrNull;
    if (profile != null && binding.matches(profile)) return profile;
    _bindingsById.remove(binding.profile.id);
    _bindingsByToken.remove(token);
    _schedulePublish();
    return null;
  }

  static String _label(String input, int maxBytes, String fallback) {
    final text = input
        .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]'), ' ')
        .trim();
    if (text.isEmpty) return fallback;
    final result = StringBuffer();
    var bytes = 0;
    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      final size = utf8.encode(character).length;
      if (bytes + size > maxBytes) break;
      result.write(character);
      bytes += size;
    }
    return result.toString();
  }

  void _schedulePublish() {
    if (_disposed || _publishScheduled) return;
    _publishScheduled = true;
    scheduleMicrotask(() {
      _publishScheduled = false;
      if (_disposed) return;
      final snapshot = _snapshot();
      final encoded = jsonEncode(snapshot);
      if (encoded == _lastPublished) return;
      _lastPublished = encoded;
      _writes = _writes.then((_) async {
        if (_disposed) return;
        try {
          await _channel.invokeMethod<void>('setTrayState', snapshot);
        } catch (_) {
          // The window remains usable when a tray icon/channel is unavailable.
          _lastPublished = null;
        }
      });
    });
  }

  Future<bool> _action(Map arguments) async {
    final action = arguments['action'];
    if (action is! String) return false;
    final expectedKeys = switch (action) {
      'selectServer' => {'action', 'serverId'},
      'setTunnel' => {'action', 'tunnel'},
      'toggleConnection' ||
      'importClipboard' ||
      'showSettings' ||
      'quit' => {'action'},
      _ => <String>{},
    };
    if (expectedKeys.isEmpty ||
        arguments.length != expectedKeys.length ||
        !arguments.keys.every(expectedKeys.contains)) {
      return false;
    }
    if (action == 'quit') return _quit();
    if (_quitting) return false;
    if (action == 'showSettings') {
      try {
        await _channel.invokeMethod<void>('showWindow');
        if (!_disposed) _navigate('/settings');
        return !_disposed;
      } catch (_) {
        return false;
      }
    }
    if (_busy) return false;
    final generation = ++_generation;
    _mutating = true;
    _schedulePublish();
    try {
      if (action != 'importClipboard') {
        final ready = await _container
            .read(connectionNotifierProvider.notifier)
            .prepareTrayAction();
        if (!_current(generation)) return false;
        if (!ready || _connection.isBusy) {
          await _showHome();
          if (!ready) _showError(_strings.vpnStatusUnavailable);
          return false;
        }
      }
      switch (action) {
        case 'toggleConnection':
          if (_connection.isConnected) {
            return await _stop(generation);
          }
          final selected = _container.read(selectedServerProvider);
          if (selected == null ||
              !(_container.read(vpnDisclosureProvider).value ?? false)) {
            await _showHome();
            return false;
          }
          return _connect(selected, generation);
        case 'selectServer':
          final token = arguments['serverId'];
          if (token is! String) return false;
          final profile = _profileForToken(token);
          if (profile == null) return false;
          if (_container.read(selectedServerProvider)?.id == profile.id) {
            return true;
          }
          final reconnect = _connection.isConnected;
          if (!await _stop(generation)) return false;
          final current = _profileForToken(token);
          if (current == null) return false;
          final selectedCurrent = await _container
              .read(serversNotifierProvider.notifier)
              .selectServerIfCurrent(current);
          if (!_current(generation) || !selectedCurrent) return false;
          if (reconnect) {
            final selected = _container.read(selectedServerProvider);
            final bound = _profileForToken(token);
            if (selected == null ||
                bound == null ||
                !current.hasSameConnectionIdentity(selected) ||
                !bound.hasSameConnectionIdentity(selected))
              return false;
            return _connect(selected, generation);
          }
          return _current(generation);
        case 'setTunnel':
          final tunnel = arguments['tunnel'];
          if (tunnel is! bool) return false;
          final settings = await _container.read(settingsProvider.future);
          if (!_current(generation)) return false;
          final mode = tunnel ? ConnectionMode.tunnel : ConnectionMode.proxy;
          if (settings.connectionMode == mode) return true;
          final reconnect = _connection.isConnected;
          if (!await _stop(generation)) return false;
          await _container
              .read(settingsProvider.notifier)
              .setConnectionMode(mode);
          if (!_current(generation)) return false;
          final selected = _container.read(selectedServerProvider);
          if (reconnect && selected != null) {
            return _connect(selected, generation);
          }
          return _current(generation);
        case 'importClipboard':
          await _channel.invokeMethod<void>('showWindow');
          ClipboardData? data;
          try {
            data = await _readClipboard();
          } catch (_) {
            if (_current(generation)) {
              _navigate('/converter');
              _showError(
                _strings.locale == 'ru'
                    ? 'Буфер обмена недоступен. Вставьте текст вручную.'
                    : 'Clipboard is unavailable. Paste the text manually.',
              );
            }
            return false;
          }
          if (!_current(generation)) return false;
          final text = data?.text;
          if (text == null || text.trim().isEmpty) {
            _navigate('/converter');
            _showError(
              _strings.locale == 'ru'
                  ? 'Буфер обмена пуст'
                  : 'Clipboard is empty',
            );
            return false;
          }
          _navigate(
            '/converter?initialText=${Uri.encodeComponent(text)}'
            '&importActivation=tray-${++_importActivation}',
          );
          return true;
      }
      return false;
    } on SettingsPersistenceException {
      if (_current(generation)) {
        await _showHome();
        _showError(_strings.settingsSaveFailed);
      }
      return false;
    } catch (_) {
      if (_current(generation)) {
        await _showHome();
        _showError(_strings.vpnStopFailed);
      }
      return false;
    } finally {
      _mutating = false;
      _schedulePublish();
    }
  }

  Future<bool> _stop(int generation) async {
    await _container.read(connectionNotifierProvider.notifier).disconnect();
    if (!_current(generation)) return false;
    if (_connection.status == ConnectionStatus.disconnected) return true;
    await _showHome();
    _showError(_strings.vpnStopFailed);
    return false;
  }

  Future<bool> _connect(ServerProfileModel server, int generation) async {
    await _container.read(connectionNotifierProvider.notifier).connect(server);
    if (!_current(generation)) return false;
    if (_connection.status == ConnectionStatus.error) {
      // The existing Home error explains the failed start without sending its
      // diagnostic text to the native tray or replacing it with a stop error.
      await _showHome();
      return false;
    }
    return true;
  }

  Future<void> _showHome() async {
    await _channel.invokeMethod<void>('showWindow');
    if (!_disposed) _navigate('/');
  }

  Future<bool> _quit() async {
    if (_quitting || _disposed) return false;
    _quitting = true;
    var nativeQuitAccepted = false;
    ConnectionNotifier? exitOwner;
    _generation++;
    _schedulePublish();
    try {
      final connection = _container.read(connectionNotifierProvider.notifier);
      exitOwner = connection;
      final confirmed = await connection.shutdownForExit();
      if (_disposed) return false;
      if (!confirmed) {
        await _showHome();
        _showError(_strings.vpnStopFailed);
        return false;
      }
      await _channel.invokeMethod<void>('quit');
      nativeQuitAccepted = true;
      return true;
    } catch (_) {
      if (!_disposed) {
        await _showHome();
        _showError(_strings.vpnStopFailed);
      }
      return false;
    } finally {
      if (!nativeQuitAccepted) exitOwner?.cancelExitAuthorization();
      _quitting = false;
      _schedulePublish();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    for (final close in _closeListeners) {
      close();
    }
    _bindingsById.clear();
    _bindingsByToken.clear();
    if (_started) _channel.setMethodCallHandler(null);
  }
}

class _TrayProfileBinding {
  const _TrayProfileBinding(this.token, this.profile);
  final String token;
  final ServerProfileModel profile;

  bool matches(ServerProfileModel other) =>
      profile.hasSameConnectionIdentity(other);
}
