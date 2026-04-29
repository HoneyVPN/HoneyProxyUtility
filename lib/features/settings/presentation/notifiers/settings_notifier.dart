import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/app_settings.dart';

const _settingsKey = 'nexproxy_settings';

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_settingsKey);
    if (raw == null) return const AppSettings();
    return AppSettings.fromJsonString(raw);
  }

  Future<void> _save(AppSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, s.toJsonString());
  }

  Future<void> setTheme(ThemeMode mode) async {
    final s = (state.value ?? const AppSettings()).copyWith(themeMode: mode);
    await _save(s);
    state = AsyncData(s);
  }

  Future<void> setRouting(RoutingMode mode) async {
    final s = (state.value ?? const AppSettings()).copyWith(routingMode: mode);
    await _save(s);
    state = AsyncData(s);
  }

  Future<void> setConnectionMode(ConnectionMode mode) async {
    final s = (state.value ?? const AppSettings()).copyWith(connectionMode: mode);
    await _save(s);
    state = AsyncData(s);
  }

  Future<void> setDns(DnsPreset preset, {String customUrl = ''}) async {
    final s = (state.value ?? const AppSettings()).copyWith(
      dnsPreset: preset,
      customDnsUrl: customUrl,
    );
    await _save(s);
    state = AsyncData(s);
  }

  Future<void> setFragmentation(bool v) async {
    final s = (state.value ?? const AppSettings()).copyWith(fragmentationEnabled: v);
    await _save(s);
    state = AsyncData(s);
  }

  Future<void> setMultiplexer(bool v) async {
    final s = (state.value ?? const AppSettings()).copyWith(multiplexerEnabled: v);
    await _save(s);
    state = AsyncData(s);
  }

  Future<void> setIpType(IpType v) async {
    final s = (state.value ?? const AppSettings()).copyWith(preferredIpType: v);
    await _save(s);
    state = AsyncData(s);
  }

  Future<void> setAllowLan(bool v) async {
    final s = (state.value ?? const AppSettings()).copyWith(allowLanConnections: v);
    await _save(s);
    state = AsyncData(s);
  }

  Future<void> setLocale(String locale) async {
    final s = (state.value ?? const AppSettings()).copyWith(locale: locale);
    await _save(s);
    state = AsyncData(s);
  }
}
