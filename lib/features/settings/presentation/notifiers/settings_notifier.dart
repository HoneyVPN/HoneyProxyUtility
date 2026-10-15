import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../app/l10n/supported_locale.dart';
import '../../data/models/app_settings.dart';

const _settingsKey = 'honeyvpn_settings';

/// A safe failure signal; storage errors may contain private settings or URLs.
class SettingsPersistenceException implements Exception {
  const SettingsPersistenceException({required this.storageUncertain});

  final bool storageUncertain;

  @override
  String toString() => 'Settings could not be saved';
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_settingsKey);
    if (raw == null) {
      return AppSettings(locale: ref.read(systemLocaleProvider));
    }
    return AppSettings.fromJsonString(raw);
  }

  Future<void> _save(AppSettings s) async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      throw const SettingsPersistenceException(storageUncertain: true);
    }
    final previousRaw = prefs.getString(_settingsKey);
    try {
      if (await prefs.setString(_settingsKey, s.toJsonString())) return;
    } catch (_) {
      // Do not retain or expose the platform's potentially sensitive error.
    }

    // Legacy preferences update their caches before reporting a write failure.
    // Restore only our key once. reload() may return the Windows backend cache,
    // so it cannot establish that the previous value is on disk.
    var restored = false;
    try {
      restored = previousRaw == null
          ? await prefs.remove(_settingsKey)
          : await prefs.setString(_settingsKey, previousRaw);
    } catch (_) {}
    throw SettingsPersistenceException(storageUncertain: !restored);
  }

  Future<void> _writeQueue = Future.value();

  Future<void> _update(AppSettings Function(AppSettings) transform) {
    final operation = _writeQueue.then((_) async {
      if (!ref.mounted) return;
      final current = state.value ?? await future;
      if (!ref.mounted) return;
      final updated = transform(current);
      await _save(updated);
      if (ref.mounted) state = AsyncData(updated);
    });
    _writeQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> setTheme(ThemeMode value) =>
      _update((s) => s.copyWith(themeMode: value));

  Future<void> setRouting(RoutingMode value) => _update(
    (s) => s.copyWith(
      routingMode: value == RoutingMode.rules ? RoutingMode.bypassRU : value,
    ),
  );

  Future<void> setGeoRoutingMode(GeoRoutingMode value) =>
      _update((s) => s.copyWith(geoRoutingMode: value));

  Future<void> setConnectionMode(ConnectionMode value) =>
      _update((s) => s.copyWith(connectionMode: value));

  Future<void> setFragmentation(bool value) =>
      _update((s) => s.copyWith(fragmentationEnabled: value));

  Future<void> setMultiplexer(bool value) =>
      _update((s) => s.copyWith(multiplexerEnabled: value));

  Future<void> setIpType(IpType value) =>
      _update((s) => s.copyWith(preferredIpType: value));

  Future<void> setAllowLan(bool value) =>
      _update((s) => s.copyWith(allowLanConnections: value));

  Future<void> setLocale(String value) =>
      _update((s) => s.copyWith(locale: value));

  Future<void> setTunStack(TunStack value) =>
      _update((s) => s.copyWith(tunStack: value));

  Future<void> setFakeip(bool value) =>
      _update((s) => s.copyWith(enableFakeip: value));

  Future<void> setLogLevel(LogLevel value) =>
      _update((s) => s.copyWith(logLevel: value));

  Future<void> setSocksPort(int value) => _update((s) {
    AppSettings.validatePorts(value, s.httpPort);
    return s.copyWith(socksPort: value);
  });

  Future<void> setHttpPort(int value) => _update((s) {
    AppSettings.validatePorts(s.socksPort, value);
    return s.copyWith(httpPort: value);
  });

  Future<void> setDns(DnsPreset preset, {String customUrl = ''}) {
    if (preset == DnsPreset.custom) {
      final issue = AppSettings.customDnsIssue(customUrl);
      if (issue != null) throw SettingsValidationException(issue);
    }
    return _update(
      (s) => s.copyWith(dnsPreset: preset, customDnsUrl: customUrl.trim()),
    );
  }

  Future<void> setPorts(int socks, int http) {
    AppSettings.validatePorts(socks, http);
    return _update((s) => s.copyWith(socksPort: socks, httpPort: http));
  }
}
