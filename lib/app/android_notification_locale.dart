import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/settings/presentation/notifiers/settings_notifier.dart';
import 'l10n/supported_locale.dart';

/// Keeps presentation in sync without issuing a VPN lifecycle command.
class AndroidNotificationLocaleController {
  AndroidNotificationLocaleController(
    this._container, {
    MethodChannel channel = const MethodChannel('ru.honeyvpn.proxy/vpn'),
  }) : _channel = channel;

  final ProviderContainer _container;
  final MethodChannel _channel;
  ProviderSubscription<String>? _subscription;
  String? _lastLocale;
  bool _disposed = false;

  void start() {
    if (_disposed || _subscription != null) return;
    final systemLocale = _container.read(systemLocaleProvider);
    _subscription = _container.listen<String>(
      settingsProvider.select<String>(
        (settings) => settings.value?.locale ?? systemLocale,
      ),
      (_, locale) {
        if (_disposed) return;
        final supportedLocale = locale == 'ru' ? 'ru' : 'en';
        if (_lastLocale == supportedLocale) return;
        _lastLocale = supportedLocale;
        unawaited(
          _channel
              .invokeMethod<bool>('setLocale', {'locale': supportedLocale})
              .catchError((Object _) => false),
        );
      },
      fireImmediately: true,
    );
  }

  void dispose() {
    _disposed = true;
    _subscription?.close();
    _subscription = null;
  }
}
