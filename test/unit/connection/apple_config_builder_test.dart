import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/builders/apple_config_builder.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

const _uuid = 'a3482e88-686a-4a58-8126-99c9df64b7bf';
const _node = '192.0.2.10';

Map<String, String> _links() {
  final privateKey = base64Encode(List.generate(32, (i) => i + 1));
  final publicKey = base64Encode(List.generate(32, (i) => i + 33));
  final realityKey = base64Url
      .encode(List.generate(32, (i) => i + 33))
      .replaceAll('=', '');
  final wireguard = Uri.encodeQueryComponent(
    jsonEncode({
      'privateKey': privateKey,
      'publicKey': publicKey,
      'presharedKey': base64Encode(List.generate(32, (i) => i + 65)),
      'addresses': ['10.20.0.2/32', 'fd00:20::2/128'],
      'dns': ['1.1.1.1'],
      'mtu': 1420,
      'reserved': [7, 8, 9],
    }),
  );
  final ss =
      'ss://${base64Encode(utf8.encode('chacha20-ietf-poly1305:fake-password'))}@$_node:8388#Synthetic-SS';
  final vmess = base64Encode(
    utf8.encode(
      jsonEncode({
        'v': '2',
        'ps': 'Synthetic-VMess',
        'add': _node,
        'port': '443',
        'id': _uuid,
        'aid': '0',
        'scy': 'auto',
        'net': 'tcp',
        'tls': 'tls',
        'sni': 'node.example.test',
      }),
    ),
  );
  return {
    'ss': ss,
    'vless-none':
        'vless://$_uuid@$_node:80?security=none&type=tcp#Synthetic-Plain',
    'vless-tls':
        'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=tcp#Synthetic-TLS',
    'vless-ws':
        'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=ws&path=%2Fws&host=node.example.test#Synthetic-WS',
    'vless-xhttp':
        'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=xhttp&path=%2Fxhttp&host=node.example.test&mode=auto#Synthetic-xHTTP',
    'vless-reality':
        'vless://$_uuid@$_node:443?security=reality&sni=node.example.test&fp=chrome&pbk=$realityKey&sid=abcd&type=tcp&flow=xtls-rprx-vision#Synthetic-Reality',
    'vmess': 'vmess://$vmess',
    'trojan':
        'trojan://fake-password@$_node:443?sni=node.example.test&alpn=h2%2Chttp%2F1.1#Synthetic-Trojan',
    'hysteria2':
        'hy2://fake-password@$_node:443?sni=node.example.test&obfs=salamander&obfs-password=fake-obfs-password#Synthetic-HY2',
    'tuic':
        'tuic://$_uuid:fake-password@$_node:443?sni=node.example.test&alpn=h3#Synthetic-TUIC',
    'wireguard': 'wireguard://$_node:51820?config=$wireguard#Synthetic-WG',
    'amneziawg': 'awg://$_node:51820?config=$wireguard#Synthetic-AWG',
    'shadowtls':
        'shadowtls://fake-shadow-password@$_node:443?sni=cover.example.test&version=3&inner=${Uri.encodeQueryComponent(ss)}#Synthetic-ShadowTLS',
  };
}

Future<void> _check(String binary, File file) async {
  final process = await Process.start(binary, [
    'check',
    '--disable-color',
    '-c',
    file.path,
  ], workingDirectory: file.parent.path);
  final stdout = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final stderr = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  try {
    final code = await process.exitCode.timeout(const Duration(seconds: 20));
    final lines = '${await stdout}\n${await stderr}'
        .replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '')
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    var message = lines
        .skip(lines.length > 12 ? lines.length - 12 : 0)
        .join('\n');
    if (message.length > 2000)
      message = message.substring(message.length - 2000);
    expect(code, 0, reason: '${file.uri.pathSegments.last}: $message');
  } on TimeoutException {
    process.kill();
    await process.exitCode;
    fail('${file.uri.pathSegments.last}: sing-box check exceeded 20 seconds');
  }
}

Future<void> _checkAppleIdentity(String binary) async {
  final manifest =
      jsonDecode(await File('core-lock.json').readAsString()) as Map;
  final core = manifest['sing_box'] as Map;
  final result = await Process.run(binary, [
    'version',
  ]).timeout(const Duration(seconds: 20));
  expect(
    result.exitCode,
    0,
    reason: 'The explicit Apple schema checker must run.',
  );
  final lines = (result.stdout as String).split('\n');
  expect(lines.first, 'sing-box version ${core['version']}');
  expect(
    lines.where((line) => line.startsWith('Revision:')).toList(),
    ['Revision: ${core['revision']}'],
    reason: 'Apple retains the global 1.13 identity and reserved-byte support.',
  );
}

void main() {
  const builder = AppleConfigBuilder();
  final links = _links();
  ParsedProxy proxy(String name) =>
      const LinkDispatcher().dispatch(links[name]!);
  Map<String, dynamic> config(
    String name, [
    AppSettings settings = const AppSettings(),
  ]) =>
      jsonDecode(builder.generate(proxy(name), settings))
          as Map<String, dynamic>;

  test(
    'Apple TUN requests IPv4 and IPv6 capture without a hardcoded descriptor or utun name',
    () {
      final result = config(
        'ss',
        const AppSettings(
          preferredIpType: IpType.ipv4,
          tunStack: TunStack.system,
        ),
      );
      final tun =
          (result['inbounds'] as List).singleWhere((i) => i['type'] == 'tun')
              as Map;
      expect(tun['address'], ['172.19.0.1/30', 'fdfe:dcba:9876::1/126']);
      expect(tun['auto_route'], isTrue);
      expect(tun['stack'], 'gvisor');
      expect(tun['mtu'], 1500);
      expect(tun.containsKey('interface_name'), isFalse);
      expect(tun.containsKey('file_descriptor'), isFalse);
      expect(result['route']['auto_detect_interface'], isTrue);
      expect(
        result.containsKey('experimental'),
        isFalse,
        reason:
            'Native libbox status must not require a fixed TCP 9090 listener',
      );
    },
  );

  test(
    'Apple keeps custom ports on loopback even with a legacy LAN preference',
    () {
      final result = config(
        'ss',
        const AppSettings(
          socksPort: 10808,
          httpPort: 10809,
          allowLanConnections: true,
          logLevel: LogLevel.debug,
        ),
      );
      final inbounds = (result['inbounds'] as List).cast<Map>();
      expect(
        inbounds.singleWhere((i) => i['type'] == 'socks')['listen_port'],
        10808,
      );
      expect(
        inbounds.singleWhere((i) => i['type'] == 'http')['listen_port'],
        10809,
      );
      expect(
        inbounds
            .where((i) => i['type'] != 'tun')
            .every((i) => i['listen'] == '127.0.0.1'),
        isTrue,
      );
      expect(result['log']['level'], 'debug');
    },
  );

  test('Apple keeps user DNS selection and its proxy detour', () {
    final result = config(
      'ss',
      const AppSettings(
        dnsPreset: DnsPreset.adguard,
        preferredIpType: IpType.ipv6,
      ),
    );
    final dns = result['dns'] as Map;
    final remote =
        (dns['servers'] as List).singleWhere((s) => s['tag'] == 'remote-dns')
            as Map;
    expect(remote['type'], 'https');
    expect(remote['server'], '94.140.14.14');
    expect(remote['detour'], 'proxy');
    expect(remote.containsKey('domain_strategy'), isFalse);
    expect(dns['strategy'], 'ipv6_only');
    expect(result['route']['default_domain_resolver'], {
      'server': 'local-dns',
      'strategy': 'ipv6_only',
    });
    expect((dns['servers'] as List).any((s) => s['type'] == 'fakeip'), isFalse);
    expect(
      (result['route']['rules'] as List).any(
        (r) => r['action'] == 'hijack-dns',
      ),
      isTrue,
    );
  });

  test('Apple preserves saved custom DNS ports in the shared typed policy', () {
    for (final entry in {
      'https://dns.example.test:8443/custom-dns': 8443,
      'tls://dns.example.test:8853': 8853,
    }.entries) {
      final settings = AppSettings.fromJson(
        AppSettings(
          dnsPreset: DnsPreset.custom,
          customDnsUrl: entry.key,
        ).toJson(),
      );
      final result = config('ss', settings);
      final remote =
          (result['dns']['servers'] as List).singleWhere(
                (server) => server['tag'] == 'remote-dns',
              )
              as Map;
      expect(remote['server_port'], entry.value);
      expect(remote['detour'], 'proxy');
      if (remote['type'] == 'https') expect(remote['path'], '/custom-dns');
    }
  });

  test(
    'Apple removes only Android-specific DNS probe and IPv6 routing workarounds',
    () {
      final rules = (config('ss')['route']['rules'] as List).cast<Map>();
      expect(
        rules.any(
          (r) =>
              r['action'] == 'reject' &&
              (r['port'] as List?)?.contains(853) == true,
        ),
        isFalse,
      );
      expect(
        rules.any(
          (r) =>
              r['rule_set'] == 'ru' &&
              r['ip_version'] == 6 &&
              r['outbound'] == 'proxy',
        ),
        isFalse,
      );
      final blocked = rules.indexWhere(
        (r) => r['rule_set'] == 'ru-blocked' && r['outbound'] == 'proxy',
      );
      final direct = rules.indexWhere(
        (r) => r['rule_set'] == 'ru' && r['outbound'] == 'direct',
      );
      expect(blocked, greaterThanOrEqualTo(0));
      expect(direct, greaterThan(blocked));
    },
  );

  test('Apple global mode never installs a Russian bypass rule', () {
    final route =
        config(
              'ss',
              const AppSettings(routingMode: RoutingMode.global),
            )['route']
            as Map;
    expect(route['final'], 'proxy');
    expect(route.containsKey('rule_set'), isFalse);
    expect(
      (route['rules'] as List).any((r) => r.containsKey('rule_set')),
      isFalse,
    );
  });

  test('Apple geoPaths are preserved for native App Group path rewriting', () {
    const paths = {
      'ru-blocked.srs': '/synthetic/app-cache/ru-blocked.srs',
      'ru.srs': '/synthetic/app-cache/ru.srs',
    };
    final result =
        jsonDecode(
              const AppleConfigBuilder(
                geoPaths: paths,
              ).generate(proxy('ss'), const AppSettings()),
            )
            as Map;
    final rules = (result['route']['rule_set'] as List).cast<Map>();
    expect(
      rules.singleWhere((r) => r['tag'] == 'ru-blocked')['path'],
      paths['ru-blocked.srs'],
    );
    expect(rules.singleWhere((r) => r['tag'] == 'ru')['type'], 'local');
  });

  for (final name in ['wireguard', 'amneziawg']) {
    test(
      'Apple preserves $name endpoint and its separate native TUN addresses',
      () {
        final parsed = proxy(name);
        final result = config(name);
        final endpoint = (result['endpoints'] as List).single as Map;
        final peer = (endpoint['peers'] as List).single as Map;
        expect(endpoint['address'], ['10.20.0.2/32', 'fd00:20::2/128']);
        expect(peer['address'], parsed.host);
        expect(peer['port'], parsed.port);
        expect(
          peer['pre_shared_key'],
          base64Encode(List.generate(32, (i) => i + 65)),
        );
        expect(peer['reserved'], [7, 8, 9]);
        expect(endpoint.containsKey('amnezia'), name == 'amneziawg');
        expect(
          (result['outbounds'] as List).any((o) => o['type'] == 'wireguard'),
          isFalse,
        );
      },
    );
  }

  test('Apple reuses the correct ShadowTLS inner-to-outer protocol chain', () {
    final result = config('shadowtls');
    final outbounds = (result['outbounds'] as List).cast<Map>();
    final inner = outbounds.singleWhere(
      (o) => o['tag'] == result['route']['final'],
    );
    final outer = outbounds.singleWhere((o) => o['tag'] == inner['detour']);
    expect(inner['type'], 'shadowsocks');
    expect(outer['type'], 'shadowtls');
    expect(outer['tls']['server_name'], 'cover.example.test');
    expect(outer.containsKey('detour'), isFalse);
  });

  test(
    'Apple fails explicitly for unavailable Naive and for system proxy mode',
    () {
      final naive = const LinkDispatcher().dispatch(
        'naive+quic://fake-user:fake-password@$_node:443#Synthetic-Naive',
      );
      expect(
        () => builder.generate(naive, const AppSettings()),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => builder.generate(
          proxy('ss'),
          const AppSettings(connectionMode: ConnectionMode.proxy),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  final appleBinary =
      Platform.environment['SINGBOX_APPLE_CHECK_BINARY']?.trim() ?? '';
  final androidOnly = Platform.environment['SINGBOX_CHECK_TARGET'] == 'android';
  final binary = appleBinary.isNotEmpty
      ? appleBinary
      : androidOnly
      ? ''
      : Platform.environment['SINGBOX_CHECK_BINARY']?.trim() ?? '';
  final nativeSkip = binary.isEmpty
      ? androidOnly
            ? 'Apple native checks require SINGBOX_APPLE_CHECK_BINARY in Android-only QA'
            : 'SINGBOX_APPLE_CHECK_BINARY or the standalone shared checker is not configured'
      : false;
  Future<void>? identity;
  Future<void> checkIdentity() => identity ??= _checkAppleIdentity(binary);
  final outputDirectory =
      Platform.environment['CORE_CONFIG_OUTPUT_DIR']?.trim() ?? '';
  const settings = {
    'default': AppSettings(),
    'global': AppSettings(routingMode: RoutingMode.global),
  };
  Directory? scratch;
  setUpAll(() async {
    scratch = await Directory.systemTemp.createTemp('honey-apple-core-check-');
  });
  tearDownAll(() async {
    if (scratch != null && await scratch!.exists())
      await scratch!.delete(recursive: true);
  });

  test(
    'Apple native checker matches the retained global core identity',
    checkIdentity,
    skip: nativeSkip,
  );

  test(
    'export synthetic Apple configurations for independent CLI checks',
    () async {
      final output = await Directory(outputDirectory).create(recursive: true);
      for (final setting in settings.entries) {
        for (final protocol in links.keys) {
          await File(
            '${output.path}/apple-${setting.key}-$protocol.json',
          ).writeAsString(builder.generate(proxy(protocol), setting.value));
        }
      }
    },
    skip: outputDirectory.isEmpty
        ? 'CORE_CONFIG_OUTPUT_DIR is not configured'
        : false,
  );

  for (final setting in settings.entries) {
    for (final protocol in links.keys) {
      final name = 'apple-${setting.key}-$protocol';
      test(
        'sing-box accepts $name for the injected NetworkExtension TUN',
        () async {
          await checkIdentity();
          final file = File('${scratch!.path}/$name.json');
          await file.writeAsString(
            builder.generate(proxy(protocol), setting.value),
          );
          await _check(binary, file);
        },
        skip: nativeSkip,
      );
    }
  }
}
