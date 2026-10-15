import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/singbox_datasource.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/singbox_config_generator.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/servers/data/services/profile_latency_service.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

ParsedProxy _profile(bool awg, List<int>? reserved) => awg
    ? AmneziaWGConfig(
        name: 'Synthetic AWG',
        host: 'peer.example.test',
        port: 51820,
        privateKey: 'synthetic-private-key',
        publicKey: 'synthetic-public-key',
        presharedKey: '',
        addresses: ['10.20.0.2/32'],
        dns: [],
        mtu: 1420,
        reserved: reserved,
      )
    : WireGuardConfig(
        name: 'Synthetic WG',
        host: 'peer.example.test',
        port: 51820,
        privateKey: 'synthetic-private-key',
        publicKey: 'synthetic-public-key',
        presharedKey: '',
        addresses: ['10.20.0.2/32'],
        dns: [],
        mtu: 1420,
        reserved: reserved,
      );
List<int>? _reserved(ParsedProxy p) => switch (p) {
  WireGuardConfig c => c.reserved,
  AmneziaWGConfig c => c.reserved,
  _ => null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final awg in [false, true]) {
    final label = awg ? 'AWG' : 'WG';
    test(
      'Android $label omits only no-effect reserved and preserves Apple/profile bytes',
      () {
        for (final reserved in <List<int>?>[
          null,
          [],
          [0, 0, 0],
        ]) {
          final p = _profile(awg, reserved);
          final android = jsonDecode(
            const SingboxConfigGenerator().generateForAndroid(
              p,
              const AppSettings(),
            ),
          );
          expect(
            (android['endpoints'][0]['peers'][0] as Map).containsKey(
              'reserved',
            ),
            isFalse,
          );
          final apple = jsonDecode(
            const SingboxConfigGenerator(
              target: SingboxConfigTarget.apple,
            ).generateForAndroid(p, const AppSettings()),
          );
          expect(
            (apple['endpoints'][0]['peers'][0] as Map).containsKey('reserved'),
            reserved != null,
          );
          expect(apple['endpoints'][0]['peers'][0]['reserved'], reserved);
          expect(_reserved(p), same(reserved));
          if (!awg) {
            final ping = jsonDecode(
              const SingboxConfigGenerator().generateForPing(p, 9099),
            );
            expect(
              (ping['endpoints'][0]['peers'][0] as Map).containsKey('reserved'),
              isFalse,
            );
          }
        }
      },
    );
    test(
      'Android $label rejects unsupported and malformed cached reserved before native/geodata work',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const methods = MethodChannel('ru.honeyvpn.proxy/vpn');
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
        final source = VpnDatasource(
          platform: VpnPlatform.android,
          onStatusChanged: (_) {},
        );
        addTearDown(source.dispose);
        for (final reserved in <List<int>>[
          [1, 0, 0],
          [0, 7, 0],
          [0, 0, 9],
          [0, 0],
          [0, 0, 0, 0],
          [-1, 0, 0],
          [256, 0, 0],
        ]) {
          final p = _profile(awg, reserved);
          final reason = throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'safe reason',
              allOf(
                contains('Android'),
                contains('reserved'),
                isNot(contains('synthetic-private-key')),
              ),
            ),
          );
          expect(
            () => const SingboxConfigGenerator().generateForAndroid(
              p,
              const AppSettings(),
            ),
            reason,
          );
          expect(
            () => const SingboxConfigGenerator().generateForPing(p, 9099),
            reason,
          );
          await expectLater(source.start(p), reason);
          expect(calls, isEmpty);
          expect(_reserved(p), same(reserved));
          final apple = jsonDecode(
            const SingboxConfigGenerator(
              target: SingboxConfigTarget.apple,
            ).generateForAndroid(p, const AppSettings()),
          );
          expect(apple['endpoints'][0]['peers'][0]['reserved'], reserved);
        }
      },
    );
    test(
      'Production latency keeps $label unavailable without launching an endpoint tunnel',
      () {
        for (final reserved in <List<int>?>[
          null,
          [],
          [0, 0, 0],
          [7, 8, 9],
        ]) {
          expect(
            () => IsolatedCoreLatencyService.configuration(
              _profile(awg, reserved),
              9099,
              'synthetic-secret',
            ),
            throwsUnsupportedError,
          );
        }
      },
    );
  }
}
