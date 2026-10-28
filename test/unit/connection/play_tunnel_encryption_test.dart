import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/app/flavor.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/singbox_datasource.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/singbox_config_generator.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/vpn_core_status.dart';
import 'package:honeyproxyutility/features/connection/domain/validation/play_tunnel_encryption.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/data/services/profile_latency_service.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _endpoint = 'vpn.example.test';
const _uuid = '00000000-0000-4000-8000-000000000000';
const _plaintextVless = 'vless://$_uuid@$_endpoint:443?security=none';
const _tlsVless = 'vless://$_uuid@$_endpoint:443?security=tls';

ParsedProxy _parse(String link) => const LinkDispatcher().dispatch(link);
String _ss(String cipher, {String plugin = ''}) =>
    'ss://${base64Encode(utf8.encode('$cipher:synthetic-secret'))}'
    '@$_endpoint:443${plugin.isEmpty ? '' : '?plugin=${Uri.encodeQueryComponent(plugin)}'}';
String _vmess(String cipher, {bool tls = false}) =>
    'vmess://${base64Encode(utf8.encode(jsonEncode({'add': _endpoint, 'port': 443, 'id': _uuid, 'scy': cipher, 'net': 'tcp', 'tls': tls ? 'tls' : ''})))}';
String _shadowTls(String inner) =>
    'shadowtls://synthetic-cover-secret@$_endpoint:443?version=3'
    '&sni=cover.example.test&inner=${Uri.encodeQueryComponent(inner)}';

class _ProbeSource extends VpnDatasource {
  _ProbeSource() : super(onStatusChanged: (_) {});
  int initializations = 0;
  int permissions = 0;
  int starts = 0;

  @override
  bool get requiresNativeSessionDiscovery => false;
  @override
  Future<VpnCoreStatus?> readCurrentStatus() async =>
      const VpnCoreStatus(state: 'DISCONNECTED');
  @override
  Future<void> initialize() async => initializations++;
  @override
  Future<bool> requestPermission() async {
    permissions++;
    return true;
  }

  @override
  Future<void> start(
    ParsedProxy proxy, {
    ConnectionMode mode = ConnectionMode.tunnel,
    AppSettings settings = const AppSettings(),
  }) async => starts++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final unencrypted = <String, String>{
    'VLESS even on port443': _plaintextVless,
    'Trojan explicitly without TLS':
        'trojan://synthetic-secret@$_endpoint:443?security=none',
    for (final cipher in ['', 'none', 'zero', 'unknown'])
      'VMess $cipher without TLS': _vmess(cipher),
    for (final cipher in ['', 'none', 'plain', 'dummy', 'unknown'])
      'Shadowsocks $cipher': _ss(cipher),
    'Shadowsocks obfs=tls is not encryption': _ss(
      'none',
      plugin: 'obfs-local;obfs=tls',
    ),
    'ShadowTLS with unencrypted SS inside': _shadowTls(_ss('none')),
  };

  for (final entry in unencrypted.entries) {
    test('Play refuses ${entry.key}; direct leaves profile unchanged', () {
      final proxy = _parse(entry.value);
      expect(
        () => validatePlayTunnelEncryption(proxy, playFlavor: true),
        throwsA(isA<PlayTunnelEncryptionException>()),
      );
      expect(
        () => validatePlayTunnelEncryption(proxy, playFlavor: false),
        returnsNormally,
      );
      // Credentials/endpoints must not appear in the presentation exception.
      try {
        validatePlayTunnelEncryption(proxy, playFlavor: true);
      } on PlayTunnelEncryptionException catch (error) {
        expect(error.toString(), isNot(contains('synthetic-secret')));
        expect(error.toString(), isNot(contains(_endpoint)));
      }
    });
  }

  final encryptionKey = base64Url
      .encode(List.generate(32, (index) => index + 1))
      .replaceAll('=', '');
  final encrypted = <String, String>{
    'VLESS TLS with encryption=none': _tlsVless,
    'VLESS REALITY':
        'vless://$_uuid@$_endpoint:443?security=reality&pbk=$encryptionKey',
    'VLESS Encryption without TLS':
        'vless://$_uuid@$_endpoint:443?encryption=mlkem768x25519plus.native.0rtt.$encryptionKey',
    'Trojan TLS': 'trojan://synthetic-secret@$_endpoint:443',
    for (final cipher in ['auto', 'aes-128-gcm', 'chacha20-poly1305'])
      'VMess $cipher': _vmess(cipher),
    'VMess none within TLS': _vmess('none', tls: true),
    for (final cipher in [
      'aes-128-gcm',
      'aes-192-gcm',
      'aes-256-gcm',
      'chacha20-ietf-poly1305',
      'xchacha20-ietf-poly1305',
      '2022-blake3-aes-128-gcm',
      '2022-blake3-aes-256-gcm',
      '2022-blake3-chacha20-poly1305',
    ])
      'Shadowsocks $cipher': _ss(cipher),
    'ShadowTLS with encrypted SS inside': _shadowTls(
      _ss('chacha20-ietf-poly1305'),
    ),
    'Hysteria2': 'hy2://synthetic-secret@$_endpoint:443',
    'TUIC': 'tuic://$_uuid:synthetic-secret@$_endpoint:443',
  };
  for (final entry in encrypted.entries) {
    test('Play retains encrypted ${entry.key}', () {
      expect(
        () =>
            validatePlayTunnelEncryption(_parse(entry.value), playFlavor: true),
        returnsNormally,
      );
    });
  }

  test('WireGuard and AWG do not require a separate TLS wrapper', () {
    final config = Uri.encodeQueryComponent(
      jsonEncode({
        'privateKey': base64Encode(List.filled(32, 1)),
        'publicKey': base64Encode(List.filled(32, 2)),
        'addresses': ['10.0.0.2/32'],
      }),
    );
    for (final scheme in ['wireguard', 'awg']) {
      expect(
        () => validatePlayTunnelEncryption(
          _parse('$scheme://$_endpoint:51820?config=$config'),
          playFlavor: true,
        ),
        returnsNormally,
      );
    }
  });

  test('both Android config and latency paths apply the compiled flavor', () {
    final proxy = _parse(_plaintextVless);
    const generator = SingboxConfigGenerator();
    final calls = <void Function()>[
      () => generator.generateForAndroid(proxy, const AppSettings()),
      () => generator.generateForPing(proxy, 19090),
      () => IsolatedCoreLatencyService.configuration(proxy, 19090, 'test-nonce'),
    ];
    for (final call in calls) {
      expect(
        call,
        isPlayFlavor
            ? throwsA(isA<PlayTunnelEncryptionException>())
            : returnsNormally,
      );
    }
    expect(
      () =>
          generator.generateForAndroid(_parse(_tlsVless), const AppSettings()),
      returnsNormally,
    );
  });

  for (final locale in ['ru', 'en']) {
    test(
      'saved plaintext profile is gated before native work ($locale)',
      () async {
        SharedPreferences.setMockInitialValues({
          'honeyvpn_settings': AppSettings(locale: locale).toJsonString(),
        });
        final sources = <_ProbeSource>[];
        final container = ProviderContainer(
          overrides: [
            vpnDatasourceFactoryProvider.overrideWithValue(({
              required void Function(VpnCoreStatus) onStatusChanged,
              void Function(String)? onError,
            }) {
              final source = _ProbeSource();
              sources.add(source);
              return source;
            }),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(connectionNotifierProvider.notifier);
        await Future<void>.delayed(Duration.zero);
        await notifier.connect(
          ServerProfileModel(
            id: 7,
            protocol: 'vless',
            name: 'Saved before Play upgrade',
            host: _endpoint,
            port: 443,
            configJson: jsonEncode({'rawLink': _plaintextVless}),
            subscriptionId: '',
            addedAt: DateTime(2026),
          ),
        );
        final state = container.read(connectionNotifierProvider);
        if (isPlayFlavor) {
          expect(state.status, ConnectionStatus.error);
          expect(
            state.errorMessage,
            container.read(stringsProvider).playEncryptedTunnelRequired,
          );
          expect(
            sources.fold<int>(0, (sum, source) => sum + source.initializations),
            0,
          );
          expect(
            sources.fold<int>(0, (sum, source) => sum + source.permissions),
            0,
          );
          expect(sources.fold<int>(0, (sum, source) => sum + source.starts), 0);
        } else {
          expect(state.errorMessage, isNull);
          expect(sources.fold<int>(0, (sum, source) => sum + source.starts), 1);
        }
      },
    );
  }

  test(
    'Android datasource refuses plaintext before platform or geo work',
    () async {
      if (!isPlayFlavor) return;
      const methods = MethodChannel('ru.honeyvpn.proxy/vpn');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async {
            calls.add(call.method);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, null),
      );
      final source = VpnDatasource(
        platform: VpnPlatform.android,
        onStatusChanged: (_) {},
      );
      addTearDown(source.dispose);
      await expectLater(
        source.start(_parse(_plaintextVless)),
        throwsA(isA<PlayTunnelEncryptionException>()),
      );
      expect(calls, isEmpty);
    },
  );
}
