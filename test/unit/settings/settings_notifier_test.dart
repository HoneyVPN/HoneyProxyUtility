import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/settings/presentation/notifiers/settings_notifier.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/singbox_config_generator.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'rapid independent changes are serialized without losing settings',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await Future.wait([
        notifier.setSocksPort(10808),
        notifier.setHttpPort(10809),
        notifier.setLocale('ru'),
        notifier.setTheme(ThemeMode.dark),
      ]);
      final current = container.read(settingsProvider).requireValue;
      expect(current.socksPort, 10808);
      expect(current.httpPort, 10809);
      expect(current.locale, 'ru');
      expect(current.themeMode, ThemeMode.dark);
      final prefs = await SharedPreferences.getInstance();
      final stored = AppSettings.fromJsonString(
        prefs.getString('honeyvpn_settings')!,
      );
      expect(stored.socksPort, 10808);
      expect(stored.httpPort, 10809);
      expect(stored.locale, 'ru');
    },
  );
  test('port pair is validated and persisted together', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    final notifier = container.read(settingsProvider.notifier);
    expect(() => notifier.setPorts(2080, 2080), throwsArgumentError);
    expect(() => notifier.setPorts(0, 65536), throwsArgumentError);
    expect(() => notifier.setPorts(9090, 8080), throwsArgumentError);
    expect(() => notifier.setPorts(8080, 9090), throwsArgumentError);
    await notifier.setPorts(10808, 10809);
    expect(container.read(settingsProvider).requireValue.socksPort, 10808);
    expect(container.read(settingsProvider).requireValue.httpPort, 10809);
  });

  test(
    'saved settings reload into the actual Android DNS, routing and listener policy',
    () async {
      const proxy = ShadowsocksConfig(
        name: 'Test',
        host: 'example.com',
        port: 443,
        method: 'chacha20-ietf-poly1305',
        password: 'fixture',
        plugin: '',
        pluginOpts: '',
      );
      var container = ProviderContainer();
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await Future.wait([
        notifier.setDns(
          DnsPreset.custom,
          customUrl: 'https://dns.example:8443/custom-query',
        ),
        notifier.setRouting(RoutingMode.global),
        notifier.setIpType(IpType.ipv6),
        notifier.setLogLevel(LogLevel.trace),
        notifier.setFragmentation(true),
        notifier.setMultiplexer(true),
        notifier.setAllowLan(true),
        notifier.setPorts(12080, 12081),
      ]);
      container.dispose();
      container = ProviderContainer();
      addTearDown(container.dispose);
      final reloaded = await container.read(settingsProvider.future);
      final config =
          jsonDecode(
                const SingboxConfigGenerator().generateForAndroid(
                  proxy,
                  reloaded,
                ),
              )
              as Map;
      expect(config['log']['level'], 'trace');
      expect(config['dns']['strategy'], 'ipv6_only');
      expect(config['route']['default_domain_resolver'], {
        'server': 'local-dns',
        'strategy': 'ipv6_only',
      });
      final remote = (config['dns']['servers'] as List).cast<Map>().singleWhere(
        (s) => s['tag'] == 'remote-dns',
      );
      expect(remote['server'], 'dns.example');
      expect(remote['path'], '/custom-query');
      expect(remote['server_port'], 8443);
      expect(remote.containsKey('domain_strategy'), isFalse);
      expect(config['route'].containsKey('rule_set'), isFalse);
      final fragment = (config['route']['rules'] as List)
          .cast<Map>()
          .singleWhere((s) => s['tls_fragment'] == true);
      expect(fragment['network'], 'tcp');
      expect(fragment['protocol'], 'tls');
      final inbounds = (config['inbounds'] as List).cast<Map>();
      expect(inbounds.map((s) => s['listen_port']), [12080, 12081]);
      expect(inbounds.every((s) => s['listen'] == '0.0.0.0'), isTrue);
      expect(config['outbounds'].first['multiplex']['enabled'], isTrue);
    },
  );

  test(
    'invalid individual ports and DNS updates keep the previous saved policy',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final original = await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await expectLater(notifier.setSocksPort(9090), throwsArgumentError);
      await expectLater(
        notifier.setHttpPort(original.socksPort),
        throwsArgumentError,
      );
      expect(
        () => notifier.setDns(
          DnsPreset.custom,
          customUrl: 'https://secret@dns.invalid/query',
        ),
        throwsArgumentError,
      );
      expect(
        container.read(settingsProvider).requireValue.toJson(),
        original.toJson(),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('honeyvpn_settings'), isNull);
    },
  );

  test(
    'legacy redundant rules and malformed ports migrate without resetting other choices',
    () async {
      SharedPreferences.setMockInitialValues({
        'honeyvpn_settings': jsonEncode({
          'themeMode': 99,
          'routingMode': 'rules',
          'locale': 'ru',
          'socksPort': 9090,
          'httpPort': 8080,
          'dnsPreset': 'google',
          'fragmentationEnabled': true,
        }),
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final reloaded = await container.read(settingsProvider.future);
      expect(reloaded.themeMode, ThemeMode.system);
      expect(reloaded.routingMode, RoutingMode.bypassRU);
      expect(reloaded.locale, 'ru');
      expect(reloaded.socksPort, 2080);
      expect(reloaded.httpPort, 8080);
      expect(reloaded.dnsPreset, DnsPreset.google);
      expect(reloaded.fragmentationEnabled, isTrue);
    },
  );

  for (final initialFailure in [false, true]) {
    for (final rollbackFailure in [null, false, true]) {
      test(
        'failed ${initialFailure ? "throwing" : "false"} save retains committed settings with rollback $rollbackFailure',
        () async {
          const original = AppSettings(
            locale: 'en',
            dnsPreset: DnsPreset.google,
          );
          SharedPreferences.setMockInitialValues({
            'honeyvpn_settings': original.toJsonString(),
            'unrelated': 'retained',
          });
          final store = _SettingsFailureStore(
            await SharedPreferencesStorePlatform.instance.getAll(),
            outcomes: [initialFailure, rollbackFailure],
          );
          SharedPreferencesStorePlatform.instance = store;
          final container = ProviderContainer();
          addTearDown(container.dispose);
          await container.read(settingsProvider.future);
          final notifier = container.read(settingsProvider.notifier);
          await expectLater(
            notifier.setDns(
              DnsPreset.custom,
              customUrl: 'https://private.example.test/dns-query',
            ),
            throwsA(
              isA<SettingsPersistenceException>()
                  .having(
                    (error) => error.storageUncertain,
                    'uncertainty when rollback did not succeed',
                    rollbackFailure != null,
                  )
                  .having(
                    (error) => error.toString(),
                    'safe error',
                    isNot(contains('private.example')),
                  ),
            ),
          );
          expect(
            container.read(settingsProvider).requireValue.toJson(),
            original.toJson(),
          );
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('honeyvpn_settings'), original.toJsonString());
          expect(prefs.getString('unrelated'), 'retained');
          expect(store.settingsWrites, 2);
          expect(store.otherWrites, 0);
          container.invalidate(settingsProvider);
          expect(
            (await container.read(settingsProvider.future)).toJson(),
            original.toJson(),
          );
        },
      );
    }
  }

  for (final rollbackFailure in [null, false, true]) {
    test(
      'failed first save restores absent settings key with rollback $rollbackFailure',
      () async {
        SharedPreferences.setMockInitialValues({'unrelated': 'retained'});
        final store = _SettingsFailureStore(
          await SharedPreferencesStorePlatform.instance.getAll(),
          outcomes: [false, rollbackFailure],
        );
        SharedPreferencesStorePlatform.instance = store;
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final original = await container.read(settingsProvider.future);
        await expectLater(
          container.read(settingsProvider.notifier).setTheme(ThemeMode.dark),
          throwsA(isA<SettingsPersistenceException>()),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('honeyvpn_settings'), isFalse);
        expect(prefs.getString('unrelated'), 'retained');
        expect(
          container.read(settingsProvider).requireValue.toJson(),
          original.toJson(),
        );
        expect(store.settingsWrites, 1);
        expect(store.settingsRemoves, 1);
        expect(store.otherWrites, 0);
      },
    );
  }

  test(
    'next queued update starts from last committed policy after failed save and rollback',
    () async {
      const original = AppSettings(dnsPreset: DnsPreset.google, locale: 'en');
      SharedPreferences.setMockInitialValues({
        'honeyvpn_settings': original.toJsonString(),
      });
      final store = _SettingsFailureStore(
        await SharedPreferencesStorePlatform.instance.getAll(),
        outcomes: [true, false, null],
      );
      SharedPreferencesStorePlatform.instance = store;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      final rejected = expectLater(
        notifier.setDns(DnsPreset.adguard),
        throwsA(isA<SettingsPersistenceException>()),
      );
      final next = notifier.setLocale('ru');
      await rejected;
      await next;
      final expected = original.copyWith(locale: 'ru');
      expect(
        container.read(settingsProvider).requireValue.toJson(),
        expected.toJson(),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('honeyvpn_settings'), expected.toJsonString());
      expect(store.settingsWrites, 3);
    },
  );
}

/// Models legacy Windows' mutable backend cache before a failed disk write.
/// null succeeds; false returns false; true throws. No real preferences read.
class _SettingsFailureStore extends InMemorySharedPreferencesStore {
  _SettingsFailureStore(Map<String, Object> data, {required this.outcomes})
    : super.withData(data);

  final List<bool?> outcomes;
  int settingsWrites = 0;
  int settingsRemoves = 0;
  int otherWrites = 0;

  bool _complete() {
    final outcome = outcomes.isEmpty ? null : outcomes.removeAt(0);
    if (outcome == true) throw StateError('synthetic private storage failure');
    return outcome == null;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await super.setValue(valueType, key, value);
    if (key != 'flutter.honeyvpn_settings') {
      otherWrites++;
      return true;
    }
    settingsWrites++;
    return _complete();
  }

  @override
  Future<bool> remove(String key) async {
    await super.remove(key);
    if (key != 'flutter.honeyvpn_settings') {
      otherWrites++;
      return true;
    }
    settingsRemoves++;
    return _complete();
  }
}
