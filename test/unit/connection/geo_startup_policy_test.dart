import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/singbox_datasource.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/vpn_datasource_windows.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/geo_data_manager.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/provider_geo_bundle.dart';
import 'package:honeyproxyutility/features/connection/data/windows/windows_session.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/vless_parser.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

class _SupportPath extends PathProviderPlatform {
  _SupportPath(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

// Deliberately stop before a real session can be reserved or a process started.
class _CaptureBackend implements WindowsSessionBackend {
  Map<String, dynamic>? config;
  @override
  Duration get monotonicTime => Duration.zero;
  @override
  Future<WindowsSession?> readActive() async => null;
  @override
  Future<WindowsSession> reserve(
    Map<String, dynamic> value, {
    required bool tunnel,
    required int httpPort,
    String? proxyIp,
  }) async {
    config = value;
    throw StateError('synthetic-reservation-stop');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final originalProvider = PathProviderPlatform.instance;
  const methods = MethodChannel('ru.honeyvpn.proxy/vpn');
  const events = EventChannel('ru.honeyvpn.proxy/vpn_stats');
  final proxy = const VlessParser().parse(
    'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@192.0.2.10:443?security=none&type=tcp',
  );
  final bundle = ProviderGeoBundle.fromJson({
    'schema': 1,
    'scope': '1' * 64,
    'metadataDigest': '2' * 64,
    'groups': {
      'block': <Map<String, dynamic>>[],
      'proxy': <Map<String, dynamic>>[],
      'direct': [
        {
          'domain': ['direct.example.test'],
        },
      ],
    },
  });
  late Directory support;
  var assetReads = 0;
  Map<String, dynamic>? androidConfig;
  setUp(() async {
    support = await Directory.systemTemp.createTemp('honey-geo-policy-');
    PathProviderPlatform.instance = _SupportPath(support.path);
    // This is a real broken cache, not an injected predicate return value.
    await File('${support.path}/geo').writeAsString('not-a-directory');
    GeoDataManager.invalidate();
    assetReads = 0;
    androidConfig = null;
    messenger.setMockMessageHandler('flutter/assets', (_) async {
      assetReads++;
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (_, sink) {}),
    );
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'start') {
        androidConfig =
            jsonDecode((call.arguments as Map)['config'] as String)
                as Map<String, dynamic>;
      }
      return null;
    });
  });
  tearDown(() async {
    messenger.setMockMessageHandler('flutter/assets', null);
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
    PathProviderPlatform.instance = originalProvider;
    GeoDataManager.invalidate();
    await support.delete(recursive: true);
  });

  for (final settings in [
    const AppSettings(routingMode: RoutingMode.global),
    const AppSettings(geoRoutingMode: GeoRoutingMode.provider),
  ]) {
    final name = settings.routingMode == RoutingMode.global
        ? 'global'
        : 'provider-only';
    test(
      'Android $name starts without reading a broken unused built-in cache',
      () async {
        final source = VpnDatasource(
          platform: VpnPlatform.android,
          onStatusChanged: (_) {},
        );
        source.bindProviderRouting(bundle);
        try {
          await source.start(proxy, settings: settings);
          expect(assetReads, 0);
          expect(androidConfig, isNotNull);
          final route = androidConfig!['route'] as Map;
          expect(jsonEncode(route), isNot(contains('ru-blocked')));
          expect(
            (route['rules'] as List).any((r) => r['protocol'] == 'dns'),
            isTrue,
          );
          if (name == 'provider-only') {
            expect(jsonEncode(route), contains(bundle.tag('direct')));
          }
        } finally {
          await source.stop();
          source.dispose();
        }
      },
    );
    test(
      'Windows Proxy $name reaches reservation with no built-in cache access',
      () async {
        final backend = _CaptureBackend();
        final source = WindowsVpnDatasource(
          onStatusChanged: (_) {},
          sessionBackend: backend,
        );
        source.bindProviderRouting(bundle);
        try {
          await expectLater(
            source.start(proxy, mode: ConnectionMode.proxy, settings: settings),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'synthetic-reservation-stop',
              ),
            ),
          );
          expect(assetReads, 0);
          expect(backend.config, isNotNull);
          expect(
            jsonEncode(backend.config!['route']),
            isNot(contains('ru-blocked')),
          );
          if (name == 'provider-only') {
            expect(
              jsonEncode(backend.config!['route']),
              contains(bundle.tag('direct')),
            );
          }
        } finally {
          source.dispose();
        }
      },
    );
  }
  for (final mode in [GeoRoutingMode.builtIn, GeoRoutingMode.combined]) {
    test(
      'Android ${mode.name} retains the required cache failure before native start',
      () async {
        final source = VpnDatasource(
          platform: VpnPlatform.android,
          onStatusChanged: (_) {},
        );
        source.bindProviderRouting(bundle);
        try {
          await expectLater(
            source.start(proxy, settings: AppSettings(geoRoutingMode: mode)),
            throwsA(isA<FileSystemException>()),
          );
          expect(androidConfig, isNull);
        } finally {
          source.dispose();
        }
      },
    );
  }
}
