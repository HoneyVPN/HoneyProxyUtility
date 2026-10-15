import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/vpn_datasource_windows.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/singbox_config_generator.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';
import 'package:honeyproxyutility/features/servers/data/services/profile_latency_service.dart';

// Check Android/Windows against their effective 1.14 identity; Apple stays 1.13:
// SINGBOX_CHECK_BINARY=/path/to/old-core
// SINGBOX_WINDOWS_CHECK_BINARY=/path/to/new-core flutter test <this file>
// SINGBOX_CHECK_TARGET=android or windows selects native checks while retaining
// all serializer assertions. Each configured checker must match that platform
// core-lock identity; a shared path cannot substitute an older Windows core.
// CORE_CONFIG_OUTPUT_DIR=/tmp/honey-core-fixtures exports the same configurations
// for `sing-box check -c file.json` on another host, even without a local core.
// All addresses and credentials below are synthetic. Only `check` is invoked;
// no VPN process is started, and no connection to these nodes is attempted.
const _uuid = 'a3482e88-686a-4a58-8126-99c9df64b7bf';
const _node = '192.0.2.10';

Map<String, String> _protocolLinks({List<int>? reserved}) {
  final privateKey = base64Encode(List.generate(32, (i) => i + 1));
  final publicKey = base64Encode(List.generate(32, (i) => i + 33));
  final realityKey = base64Url
      .encode(List.generate(32, (i) => i + 33))
      .replaceAll('=', '');
  final encryptionKey = base64Url
      .encode(List.generate(32, (i) => i + 1))
      .replaceAll('=', '');
  final mlkemKey = base64Url.encode(List.filled(1184, 0)).replaceAll('=', '');
  final wireguardConfig = jsonEncode({
    'privateKey': privateKey,
    'publicKey': publicKey,
    'presharedKey': base64Encode(List.generate(32, (i) => i + 65)),
    'addresses': ['10.20.0.2/32', 'fd00:20::2/128'],
    'dns': ['1.1.1.1'],
    'mtu': 1420,
    if (reserved != null) 'reserved': reserved,
  });
  final vmess = base64Encode(
    utf8.encode(
      jsonEncode({
        'v': '2',
        'ps': 'Synthetic VMess',
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
  final ssAuth = base64Encode(
    utf8.encode('chacha20-ietf-poly1305:fake-password'),
  );
  return {
    'ss': 'ss://$ssAuth@$_node:8388#Synthetic-SS',
    'vless-none':
        'vless://$_uuid@$_node:80?security=none&type=tcp#Synthetic-VLESS',
    'vless-tls':
        'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=tcp#Synthetic-TLS',
    'vless-ws':
        'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=ws&path=%2Fws&host=node.example.test#Synthetic-WS',
    'vless-grpc':
        'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=grpc&serviceName=synthetic-service#Synthetic-gRPC',
    'vless-h2':
        'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=h2&path=%2Fh2&host=node.example.test#Synthetic-H2',
    'vless-httpupgrade':
        'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=httpupgrade&path=%2Fupgrade&host=node.example.test#Synthetic-HTTPUpgrade',
    'vless-encryption-native':
        'vless://$_uuid@$_node:443?encryption=mlkem768x25519plus.native.0rtt.$encryptionKey#Synthetic-Encryption',
    'vless-encryption-xorpub':
        'vless://$_uuid@$_node:443?encryption=mlkem768x25519plus.xorpub.1rtt.$encryptionKey#Synthetic-Encryption',
    'vless-encryption-random':
        'vless://$_uuid@$_node:443?encryption=mlkem768x25519plus.random.1rtt.100-35-35.$encryptionKey#Synthetic-Encryption',
    'vless-encryption-mlkem':
        'vless://$_uuid@$_node:443?encryption=mlkem768x25519plus.native.0rtt.$mlkemKey#Synthetic-MLKEM',
    'vless-xhttp':
        'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=xhttp&path=%2Fxhttp&host=node.example.test&mode=auto#Synthetic-xHTTP',
    'vless-xhttp-default':
        'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=xhttp&path=%2Fxhttp#Synthetic-xHTTP',
    for (final mode in ['packet-up', 'stream-up', 'stream-one'])
      'vless-xhttp-$mode':
          'vless://$_uuid@$_node:443?security=tls&sni=node.example.test&type=xhttp&mode=$mode#Synthetic-xHTTP',
    'vless-reality':
        'vless://$_uuid@$_node:443?security=reality&sni=node.example.test&fp=chrome&pbk=$realityKey&sid=abcd&type=tcp&flow=xtls-rprx-vision#Synthetic-Reality',
    'trojan':
        'trojan://fake-password@$_node:443?sni=node.example.test&alpn=h2%2Chttp%2F1.1&type=tcp#Synthetic-Trojan',
    'vmess': 'vmess://$vmess',
    'hysteria2':
        'hy2://fake-password@$_node:443?sni=node.example.test&obfs=salamander&obfs-password=fake-obfs-password#Synthetic-HY2',
    'hysteria2-hopping':
        'hy2://fake-password@$_node:443,5000-5002?sni=node.example.test&hopInterval=30s#Synthetic-Hopping',
    'hysteria2-mport':
        'hy2://user%3Afake%40password@$_node:443?sni=node.example.test&mport=443,6000-6002&hopInterval=15.5s#Synthetic-mport',
    'hysteria2-ipv6':
        'hy2://fake-password@[2001:db8::10]:443,5000-5002?sni=node.example.test#Synthetic-IPv6',
    'tuic':
        'tuic://$_uuid:fake-password@$_node:443?sni=node.example.test&alpn=h3#Synthetic-TUIC',
    'wireguard':
        'wireguard://$_node:51820?config=${Uri.encodeComponent(wireguardConfig)}#Synthetic-WG',
    'amneziawg':
        'awg://$_node:51820?config=${Uri.encodeComponent(wireguardConfig)}#Synthetic-AWG',
  };
}

String _shadowTlsLink() {
  final ssAuth = base64Encode(
    utf8.encode('chacha20-ietf-poly1305:fake-inner-password'),
  );
  final inner = 'ss://$ssAuth@$_node:8388';
  return 'shadowtls://fake-shadow-password@$_node:443?sni=cover.example.test&version=3&inner=${Uri.encodeQueryComponent(inner)}#Synthetic-ShadowTLS';
}

enum _Target { android, windowsTunnel, windowsProxy }

String _configuration(_Target target, ParsedProxy proxy, AppSettings settings) {
  if (target == _Target.android) {
    return const SingboxConfigGenerator().generateForAndroid(proxy, settings);
  }
  final mode = target == _Target.windowsTunnel
      ? ConnectionMode.tunnel
      : ConnectionMode.proxy;
  return jsonEncode(
    WindowsVpnDatasource(
      onStatusChanged: (_) {},
    ).buildConfiguration(proxy, settings, mode: mode),
  );
}

// Never let the caller environment conceal removed schema fields.
Map<String, String> get _launchEnvironment => Map.fromEntries(
  Platform.environment.entries.where(
    (entry) => !entry.key.startsWith('ENABLE_DEPRECATED_'),
  ),
);

String _checkTarget(Map<String, String> environment) {
  final target = environment['SINGBOX_CHECK_TARGET']?.trim() ?? 'all';
  if (!const ['all', 'android', 'windows'].contains(target)) {
    throw ArgumentError.value(
      target,
      'SINGBOX_CHECK_TARGET',
      'Use all, android or windows',
    );
  }
  return target;
}

String _binaryFor(_Target target) {
  if (target != _Target.android) {
    final override = Platform.environment['SINGBOX_WINDOWS_CHECK_BINARY']
        ?.trim();
    if (override != null && override.isNotEmpty) return override;
  }
  return Platform.environment['SINGBOX_CHECK_BINARY']?.trim() ?? '';
}

Object _skipCoreCheck(_Target target) {
  final scope = _checkTarget(Platform.environment);
  if (scope == 'windows' && target == _Target.android) {
    return 'This job checks the Windows core; Android checks use their explicit asset identity';
  }
  if (scope == 'android' && target != _Target.android) {
    return 'This job checks the Android core; Apple uses its separate existing identity';
  }
  return _binaryFor(target).isEmpty
      ? 'The target core checker is not configured'
      : false;
}

Map _identityFor(_Target target, Map core) => {
  ...core,
  ...core['assets'][target == _Target.android
          ? 'android-amd64'
          : 'windows-amd64']
      as Map,
};

bool _matchesCoreIdentity(String output, Map manifest) =>
    RegExp(
          r'^sing-box version ([^\s]+)',
          multiLine: true,
        ).firstMatch(output)?.group(1) ==
        manifest['version'] &&
    RegExp(
          r'^Revision: ([0-9a-f]+)',
          multiLine: true,
        ).firstMatch(output)?.group(1) ==
        manifest['revision'];

Future<void> _verifyCoreIdentity(String binary, Map manifest) async {
  final result = await Process.run(
    binary,
    ['version'],
    environment: _launchEnvironment,
    includeParentEnvironment: false,
  ).timeout(const Duration(seconds: 20));
  expect(
    result.exitCode,
    0,
    reason: 'The configured core must report its identity',
  );
  final output = '${result.stdout}\n${result.stderr}';
  expect(
    _matchesCoreIdentity(output, manifest),
    isTrue,
    reason:
        'The checker must match the pinned target version and full revision',
  );
}

String _briefDiagnostics(String stdout, String stderr) {
  final lines = '$stdout\n$stderr'
      .replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '')
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final message = lines
      .skip(lines.length > 12 ? lines.length - 12 : 0)
      .join('\n');
  if (message.isEmpty) return '(core emitted no diagnostics)';
  return message.length <= 2000
      ? message
      : message.substring(message.length - 2000);
}

Future<void> _checkCore(String binary, File config, _Target target) async {
  final process = await Process.start(
    binary,
    ['check', '--disable-color', '-c', config.path],
    workingDirectory: config.parent.path,
    environment: _launchEnvironment,
    includeParentEnvironment: false,
  );
  final stdout = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final stderr = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  try {
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 20),
    );
    final diagnostics = _briefDiagnostics(await stdout, await stderr);
    expect(
      exitCode,
      0,
      reason: '${config.uri.pathSegments.last}: $diagnostics',
    );
  } on TimeoutException {
    process.kill();
    await process.exitCode;
    fail('${config.uri.pathSegments.last}: sing-box check exceeded 20 seconds');
  }
}

void main() {
  final outputDirectory =
      Platform.environment['CORE_CONFIG_OUTPUT_DIR']?.trim() ?? '';
  final protocolLinks = _protocolLinks();
  const settings = {
    'default': AppSettings(),
    'global': AppSettings(routingMode: RoutingMode.global),
  };
  Directory? scratch;

  setUpAll(() async {
    final checkTarget = _checkTarget(Platform.environment);
    if (checkTarget == 'windows' && _binaryFor(_Target.windowsTunnel).isEmpty) {
      throw StateError('Windows native scope requires its pinned core checker');
    }
    if (checkTarget == 'android' && _binaryFor(_Target.android).isEmpty) {
      throw StateError('Android native scope requires its pinned core checker');
    }
    final core =
        (jsonDecode(await File('core-lock.json').readAsString())
                as Map)['sing_box']
            as Map;
    final verified = <String>{};
    for (final target in _Target.values) {
      if (_skipCoreCheck(target) != false) continue;
      final checker = _binaryFor(target);
      final identity = _identityFor(target, core);
      final key = '$checker:${identity['version']}:${identity['revision']}';
      if (verified.add(key)) await _verifyCoreIdentity(checker, identity);
    }
    scratch = await Directory.systemTemp.createTemp('honey-core-check-');
  });
  tearDownAll(() async {
    if (scratch != null && await scratch!.exists())
      await scratch!.delete(recursive: true);
  });

  test('Android and Windows checkers verify effective per-asset identities', () {
    final core =
        (jsonDecode(File('core-lock.json').readAsStringSync())
                as Map)['sing_box']
            as Map;
    final windows = _identityFor(_Target.windowsTunnel, core);
    expect(_identityFor(_Target.windowsProxy, core), windows);
    final android = _identityFor(_Target.android, core);
    expect(android['version'], windows['version']);
    expect(android['revision'], windows['revision']);
    expect(core['assets']['android-arm64']['version'], android['version']);
    expect(core['assets']['android-arm64']['revision'], android['revision']);
    expect(windows['version'], '1.14.1-extended-2.7.2');
    expect(windows['revision'], '55faa763f986f4ca8a492d9b2719bc6330d2bef5');
    expect(core['version'], '1.13.12-extended-2.1.2');
    final identity =
        'sing-box version ${windows['version']}\nRevision: ${windows['revision']}\n';
    expect(_matchesCoreIdentity(identity, windows), isTrue);
    expect(_matchesCoreIdentity(identity, core), isFalse);
    expect(
      _matchesCoreIdentity(
        identity.replaceFirst(
          windows['revision'],
          '0000000000000000000000000000000000000000',
        ),
        windows,
      ),
      isFalse,
    );
    expect(
      _matchesCoreIdentity('sing-box version ${windows['version']}\n', windows),
      isFalse,
    );
    expect(
      _matchesCoreIdentity(
        'sing-box version 1.14.1\nRevision: ${windows['revision']}\n',
        windows,
      ),
      isFalse,
    );
  });

  test('native check target rejects unknown scopes', () {
    expect(_checkTarget({}), 'all');
    expect(_checkTarget({'SINGBOX_CHECK_TARGET': 'windows'}), 'windows');
    expect(_checkTarget({'SINGBOX_CHECK_TARGET': 'android'}), 'android');
    for (final target in ['apple', 'Windows', '', 'all,windows']) {
      expect(
        () => _checkTarget({'SINGBOX_CHECK_TARGET': target}),
        throwsArgumentError,
      );
    }
  });

  final latencyLinks = <String, String>{
    'vless-reality': protocolLinks['vless-reality']!,
    'xhttp-auto': protocolLinks['vless-reality']!
        .replaceFirst('fp=chrome', 'fp=ios')
        .replaceFirst(
          'type=tcp&flow=xtls-rprx-vision',
          'type=xhttp&mode=auto&path=%2Fprobe',
        ),
    'hysteria2': protocolLinks['hysteria2']!,
  };
  for (final target in [_Target.android, _Target.windowsProxy]) {
    for (final entry in latencyLinks.entries) {
      String configuration() => IsolatedCoreLatencyService.configuration(
        const LinkDispatcher().dispatch(entry.value),
        9109,
        'synthetic-latency-secret',
        windowsRouting: target != _Target.android,
      );
      test(
        '${target.name} production latency ${entry.key} keeps isolated DNS/routing and profile semantics',
        () async {
          final raw = configuration();
          final config = jsonDecode(raw) as Map;
          expect(config['inbounds'], isEmpty);
          expect(config['dns'], {
            'servers': [
              {'type': 'local', 'tag': 'probe-local'},
            ],
            'final': 'probe-local',
            'strategy': 'prefer_ipv4',
          });
          expect(config['route'], {
            'default_domain_resolver': 'probe-local',
            if (target != _Target.android) 'auto_detect_interface': true,
          });
          expect(config['experimental'], {
            'clash_api': {
              'external_controller': '127.0.0.1:9109',
              'secret': 'synthetic-latency-secret',
            },
          });
          final proxy = const LinkDispatcher().dispatch(entry.value);
          final outbound = (config['outbounds'] as List).first as Map;
          expect(outbound['server'], proxy.host);
          expect(outbound['server_port'], proxy.port);
          if (proxy is VlessConfig) {
            expect(outbound['uuid'], proxy.uuid);
            expect(outbound['tls']['utls']['fingerprint'], proxy.fingerprint);
            expect(outbound['tls']['reality']['public_key'], proxy.publicKey);
            expect(outbound['tls']['reality']['short_id'], proxy.shortId);
            if (entry.key == 'xhttp-auto') {
              expect(outbound['transport']['type'], 'xhttp');
              expect(outbound['transport']['mode'], 'auto');
              expect(outbound['transport']['path'], proxy.path);
              expect(outbound['tls']['utls']['fingerprint'], 'ios');
              expect(
                outbound['tls']['reality'],
                isNot(contains('support_x25519mlkem768')),
              );
              expect(outbound, isNot(contains('flow')));
            }
          } else if (proxy is Hysteria2Config) {
            expect(outbound['type'], 'hysteria2');
            expect(outbound['password'], proxy.auth);
            expect(outbound['obfs']['type'], 'salamander');
            expect(outbound['obfs']['password'], proxy.obfsPassword);
          }
          if (outputDirectory.isNotEmpty) {
            await Directory(outputDirectory).create(recursive: true);
            await File(
              '$outputDirectory/${target.name}-latency-${entry.key}.json',
            ).writeAsString(raw);
          }
        },
      );
      test(
        'pinned ${target.name} core accepts production latency ${entry.key}',
        () async {
          final file = File(
            '${scratch!.path}/${target.name}-latency-${entry.key}.json',
          );
          await file.writeAsString(configuration());
          await _checkCore(_binaryFor(target), file, target);
        },
        skip: _skipCoreCheck(target),
      );
    }
  }

  for (final ip in IpType.values) {
    for (final preset in [
      DnsPreset.cloudflare,
      DnsPreset.google,
      DnsPreset.custom,
    ]) {
      test(
        'Android stored ${ip.name}/${preset.name} settings reach the pinned core',
        () async {
          final saved = AppSettings.fromJson(
            AppSettings(
              preferredIpType: ip,
              dnsPreset: preset,
              customDnsUrl: 'tls://dns.example.test',
              routingMode: RoutingMode.global,
              fragmentationEnabled: true,
            ).toJson(),
          );
          final proxy = const LinkDispatcher().dispatch(
            protocolLinks['vless-tls']!,
          );
          final raw = _configuration(_Target.android, proxy, saved);
          final config = jsonDecode(raw) as Map;
          final strategy = switch (ip) {
            IpType.ipv4 => 'ipv4_only',
            IpType.ipv6 => 'ipv6_only',
            IpType.both => 'prefer_ipv4',
          };
          expect(config['dns']['strategy'], strategy);
          expect(
            config['route']['default_domain_resolver']['strategy'],
            strategy,
          );
          final file = File(
            '${scratch!.path}/android-settings-${ip.name}-${preset.name}.json',
          );
          await file.writeAsString(raw);
          if (outputDirectory.isNotEmpty) {
            await Directory(outputDirectory).create(recursive: true);
            await file.copy('$outputDirectory/${file.uri.pathSegments.last}');
          }
          if (_skipCoreCheck(_Target.android) == false)
            await _checkCore(
              _binaryFor(_Target.android),
              file,
              _Target.android,
            );
        },
      );
    }
  }

  for (final entry in {
    'https://dns.example.test:8443/custom-dns': 8443,
    'tls://dns.example.test:8853': 8853,
  }.entries) {
    test(
      'Android custom DNS port ${entry.value} reaches the pinned core',
      () async {
        final saved = AppSettings.fromJson(
          AppSettings(
            dnsPreset: DnsPreset.custom,
            customDnsUrl: entry.key,
            routingMode: RoutingMode.global,
          ).toJson(),
        );
        final proxy = const LinkDispatcher().dispatch(
          protocolLinks['vless-tls']!,
        );
        final raw = _configuration(_Target.android, proxy, saved);
        final config = jsonDecode(raw) as Map;
        final remote =
            (config['dns']['servers'] as List).singleWhere(
                  (server) => server['tag'] == 'remote-dns',
                )
                as Map;
        expect(remote['server_port'], entry.value);
        final file = File(
          '${scratch!.path}/android-settings-dns-port-${entry.value}.json',
        );
        await file.writeAsString(raw);
        if (outputDirectory.isNotEmpty) {
          await Directory(outputDirectory).create(recursive: true);
          await file.copy('$outputDirectory/${file.uri.pathSegments.last}');
        }
        if (_skipCoreCheck(_Target.android) == false)
          await _checkCore(_binaryFor(_Target.android), file, _Target.android);
      },
    );
  }

  for (final target in _Target.values) {
    test(
      '${target.name} global multiplexing preserves Vision and still applies to compatible VLESS',
      () {
        final vision = const LinkDispatcher().dispatch(
          protocolLinks['vless-reality']!,
        );
        const muxSettings = AppSettings(multiplexerEnabled: true);
        final outbound =
            (jsonDecode(
                          _configuration(target, vision, muxSettings),
                        )['outbounds']
                        as List)
                    .first
                as Map;
        expect(outbound['flow'], 'xtls-rprx-vision');
        expect(outbound, isNot(contains('multiplex')));
        final ordinary = const LinkDispatcher().dispatch(
          protocolLinks['vless-none']!,
        );
        final ordinaryOutbound =
            (jsonDecode(
                          _configuration(target, ordinary, muxSettings),
                        )['outbounds']
                        as List)
                    .first
                as Map;
        expect(ordinaryOutbound['multiplex']['enabled'], isTrue);
      },
    );
    test(
      'sing-box accepts ${target.name} Vision with global multiplexing preference',
      () async {
        final vision = const LinkDispatcher().dispatch(
          protocolLinks['vless-reality']!,
        );
        final config = File(
          '${scratch!.path}/${target.name}-vision-multiplex.json',
        );
        await config.writeAsString(
          _configuration(
            target,
            vision,
            const AppSettings(multiplexerEnabled: true),
          ),
        );
        await _checkCore(_binaryFor(target), config, target);
      },
      skip: _skipCoreCheck(target),
    );
    test(
      '${target.name} retains explicit VLESS encryption/TLS/path semantics',
      () {
        final encryption =
            (const LinkDispatcher().dispatch(
                      protocolLinks['vless-encryption-native']!,
                    )
                    as VlessConfig)
                .encryption;
        final proxy = const LinkDispatcher().dispatch(
          'vless://$_uuid@$_node:443?security=tls&type=ws&path=%2F%252F&'
          'alpn=h2%2Chttp%2F1.1&allowInsecure=1&encryption=$encryption',
        );
        final outbound =
            (jsonDecode(
                          _configuration(target, proxy, const AppSettings()),
                        )['outbounds']
                        as List)
                    .first
                as Map;
        expect(outbound['encryption'], encryption);
        expect(outbound['transport']['path'], '/%2F');
        expect(outbound['tls']['alpn'], ['h2', 'http/1.1']);
        expect(outbound['tls']['insecure'], isTrue);
        final defaultOutbound =
            (jsonDecode(
                          _configuration(
                            target,
                            const LinkDispatcher().dispatch(
                              protocolLinks['vless-tls']!,
                            ),
                            const AppSettings(),
                          ),
                        )['outbounds']
                        as List)
                    .first
                as Map;
        expect(defaultOutbound, isNot(contains('encryption')));
        expect(defaultOutbound['tls'], isNot(contains('alpn')));
        expect(defaultOutbound['tls'], isNot(contains('insecure')));
      },
    );
    test(
      '${target.name} retains Hysteria2 hopping, duration and userpass auth',
      () {
        final proxy = const LinkDispatcher().dispatch(
          protocolLinks['hysteria2-mport']!,
        );
        final outbound =
            (jsonDecode(
                          _configuration(target, proxy, const AppSettings()),
                        )['outbounds']
                        as List)
                    .first
                as Map;
        expect(outbound['password'], 'user:fake@password');
        expect(outbound['server_ports'], ['443:443', '6000:6002']);
        expect(outbound['hop_interval'], '15.5s');
      },
    );
    test(
      '${target.name} rejects a cached full-certificate pin without weakening TLS',
      () {
        const proxy = Hysteria2Config(
          name: 'Synthetic',
          host: _node,
          port: 443,
          auth: 'fake-password',
          sni: 'node.example.test',
          insecure: true,
          obfs: '',
          obfsPassword: '',
          pinSha256: 'FAKE-FINGERPRINT',
        );
        expect(
          () => _configuration(target, proxy, const AppSettings()),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'safe reason',
              allOf(contains('pinSHA256'), isNot(contains('FAKE-FINGERPRINT'))),
            ),
          ),
        );
      },
    );
  }

  for (final scheme in ['https', 'quic']) {
    test(
      'Android rejects unavailable Naive $scheme without an HTTP substitution',
      () {
        final proxy = const LinkDispatcher().dispatch(
          'naive+$scheme://fake-user:fake-password@$_node:443#Synthetic-Naive',
        );
        expect(
          () => const SingboxConfigGenerator().generateForAndroid(
            proxy,
            const AppSettings(),
          ),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'reason',
              'NaiveProxy is unavailable in this core build',
            ),
          ),
        );
        expect(
          () => const SingboxConfigGenerator().generateForPing(proxy, 9099),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );
  }

  for (final target in [_Target.windowsTunnel, _Target.windowsProxy]) {
    test(
      '${target.name} explicitly rejects unimplemented Naive and ShadowTLS',
      () {
        for (final link in [
          'naive+https://fake-user:fake-password@$_node:443#Synthetic-Naive',
          _shadowTlsLink(),
        ]) {
          final proxy = const LinkDispatcher().dispatch(link);
          expect(
            () => _configuration(target, proxy, const AppSettings()),
            throwsA(isA<UnsupportedError>()),
          );
        }
      },
    );
  }

  for (final smux in [false, true]) {
    test(
      'Android ShadowTLS wraps the inner Shadowsocks connection (smux=$smux)',
      () {
        final proxy =
            const LinkDispatcher().dispatch(_shadowTlsLink())
                as ShadowTlsConfig;
        final config =
            jsonDecode(
                  const SingboxConfigGenerator().generateForAndroid(
                    proxy,
                    AppSettings(multiplexerEnabled: smux),
                  ),
                )
                as Map;
        final outbounds = (config['outbounds'] as List).cast<Map>();
        final inner = outbounds.singleWhere(
          (o) => o['tag'] == config['route']['final'],
        );
        final outer = outbounds.singleWhere((o) => o['tag'] == inner['detour']);
        expect(inner['type'], 'shadowsocks');
        expect(
          inner['password'],
          (proxy.innerProxy as ShadowsocksConfig).password,
        );
        expect(outer['type'], 'shadowtls');
        expect(outer['server'], proxy.host);
        expect(outer['password'], proxy.password);
        expect(outer['version'], proxy.version);
        expect(outer['tls']['server_name'], proxy.sni);
        expect(
          outer.containsKey('detour'),
          isFalse,
          reason:
              'The outer transport must dial the server directly, without a reversed chain',
        );
        expect(outer.containsKey('multiplex'), isFalse);
        expect(inner.containsKey('multiplex'), smux);
      },
    );
  }

  for (final setting in settings.entries) {
    test(
      'sing-box accepts Android ${setting.key} ShadowTLS + Shadowsocks',
      () async {
        final proxy = const LinkDispatcher().dispatch(_shadowTlsLink());
        final config = File(
          '${scratch!.path}/android-${setting.key}-shadowtls.json',
        );
        await config.writeAsString(
          _configuration(_Target.android, proxy, setting.value),
        );
        await _checkCore(_binaryFor(_Target.android), config, _Target.android);
      },
      skip: _skipCoreCheck(_Target.android),
    );
  }

  test(
    'sing-box accepts Android ShadowTLS latency configuration',
    () async {
      final proxy = const LinkDispatcher().dispatch(_shadowTlsLink());
      final config = File('${scratch!.path}/android-shadowtls-ping.json');
      await config.writeAsString(
        const SingboxConfigGenerator().generateForPing(proxy, 9099),
      );
      await _checkCore(_binaryFor(_Target.android), config, _Target.android);
    },
    skip: _skipCoreCheck(_Target.android),
  );

  test(
    'sing-box accepts Android ShadowTLS with multiplexing on the inner connection',
    () async {
      final proxy = const LinkDispatcher().dispatch(_shadowTlsLink());
      final config = File(
        '${scratch!.path}/android-shadowtls-multiplexer.json',
      );
      await config.writeAsString(
        _configuration(
          _Target.android,
          proxy,
          const AppSettings(multiplexerEnabled: true),
        ),
      );
      await _checkCore(_binaryFor(_Target.android), config, _Target.android);
    },
    skip: _skipCoreCheck(_Target.android),
  );

  for (final target in _Target.values) {
    test('${target.name} preserves standard WireGuard endpoint identity', () {
      final proxy =
          const LinkDispatcher().dispatch(protocolLinks['wireguard']!)
              as WireGuardConfig;
      final config =
          jsonDecode(_configuration(target, proxy, const AppSettings())) as Map;
      final endpoint = (config['endpoints'] as List).single as Map;
      final peer = (endpoint['peers'] as List).single as Map;
      expect(endpoint['type'], 'wireguard');
      expect(
        endpoint.containsKey('amnezia'),
        isFalse,
        reason: 'Plain WireGuard must not silently enable AWG obfuscation',
      );
      expect(endpoint['address'], proxy.addresses);
      expect(endpoint['private_key'], proxy.privateKey);
      expect(endpoint['mtu'], proxy.mtu);
      expect(peer['address'], proxy.host);
      expect(peer['port'], proxy.port);
      expect(peer['public_key'], proxy.publicKey);
      expect(peer['pre_shared_key'], proxy.presharedKey);
      expect(peer.containsKey('reserved'), isFalse);
      expect(proxy.reserved, isNull);
      expect(peer['allowed_ips'], ['0.0.0.0/0', '::/0']);
      expect(
        (config['outbounds'] as List).any((o) => o['type'] == 'wireguard'),
        isFalse,
      );
    });

    test(
      '${target.name} keeps TUIC transport and TLS identity without TCP smux',
      () {
        final proxy =
            const LinkDispatcher().dispatch(protocolLinks['tuic']!)
                as TuicConfig;
        final config =
            jsonDecode(
                  _configuration(
                    target,
                    proxy,
                    const AppSettings(multiplexerEnabled: true),
                  ),
                )
                as Map;
        final outbound = (config['outbounds'] as List).first as Map;
        expect(outbound['type'], 'tuic');
        expect(outbound['uuid'], proxy.uuid);
        expect(outbound['password'], proxy.password);
        expect(outbound['congestion_control'], proxy.congestionControl);
        expect(outbound['udp_relay_mode'], proxy.udpRelayMode);
        expect(outbound['tls']['server_name'], proxy.sni);
        expect(outbound['tls']['alpn'], proxy.alpn.split(','));
        expect(outbound['tls']['insecure'], proxy.allowInsecure);
        expect(outbound.containsKey('multiplex'), isFalse);
      },
    );

    test(
      'sing-box accepts ${target.name} TUIC with multiplexer setting enabled',
      () async {
        final proxy = const LinkDispatcher().dispatch(protocolLinks['tuic']!);
        final config = File(
          '${scratch!.path}/${target.name}-tuic-multiplexer.json',
        );
        await config.writeAsString(
          _configuration(
            target,
            proxy,
            const AppSettings(multiplexerEnabled: true),
          ),
        );
        await _checkCore(_binaryFor(target), config, target);
      },
      skip: _skipCoreCheck(target),
    );
  }

  for (final protocol in ['wireguard', 'amneziawg']) {
    test(
      'Apple retains $protocol reserved while Android rejects without changing the profile',
      () {
        final proxy = const LinkDispatcher().dispatch(
          _protocolLinks(reserved: [7, 8, 9])[protocol]!,
        );
        final apple =
            jsonDecode(
                  const SingboxConfigGenerator(
                    target: SingboxConfigTarget.apple,
                  ).generateForAndroid(proxy, const AppSettings()),
                )
                as Map;
        expect(apple['endpoints'][0]['peers'][0]['reserved'], [7, 8, 9]);
        expect(
          () => _configuration(_Target.android, proxy, const AppSettings()),
          throwsUnsupportedError,
        );
        expect(
          () => const SingboxConfigGenerator().generateForPing(proxy, 9099),
          throwsUnsupportedError,
        );
        for (final target in [_Target.windowsTunnel, _Target.windowsProxy]) {
          expect(
            () => _configuration(target, proxy, const AppSettings()),
            throwsUnsupportedError,
          );
        }
        expect(
          switch (proxy) {
            WireGuardConfig c => c.reserved,
            AmneziaWGConfig c => c.reserved,
            _ => null,
          },
          [7, 8, 9],
        );
      },
    );
    test(
      'effective Android core accepts $protocol omitted zero reserved',
      () async {
        final proxy = const LinkDispatcher().dispatch(
          _protocolLinks(reserved: [0, 0, 0])[protocol]!,
        );
        final raw = _configuration(_Target.android, proxy, const AppSettings());
        expect(
          (jsonDecode(raw)['endpoints'][0]['peers'][0] as Map).containsKey(
            'reserved',
          ),
          isFalse,
        );
        final config = File(
          '${scratch!.path}/android-zero-reserved-$protocol.json',
        );
        await config.writeAsString(raw);
        await _checkCore(_binaryFor(_Target.android), config, _Target.android);
      },
      skip: _skipCoreCheck(_Target.android),
    );
  }

  test(
    'Windows WireGuard binds the encrypted peer traffic to the physical interface',
    () {
      final proxy = const LinkDispatcher().dispatch(
        protocolLinks['wireguard']!,
      );
      final config = WindowsVpnDatasource(onStatusChanged: (_) {})
          .buildConfiguration(
            proxy,
            const AppSettings(),
            bindInterface: 'synthetic-physical-adapter',
          );
      expect(
        (config['endpoints'] as List).single['bind_interface'],
        'synthetic-physical-adapter',
      );
    },
  );

  test(
    'sing-box accepts the standard WireGuard Android latency configuration',
    () async {
      final proxy = const LinkDispatcher().dispatch(
        protocolLinks['wireguard']!,
      );
      final config = File('${scratch!.path}/android-wireguard-ping.json');
      await config.writeAsString(
        const SingboxConfigGenerator().generateForPing(proxy, 9099),
      );
      await _checkCore(_binaryFor(_Target.android), config, _Target.android);
    },
    skip: _skipCoreCheck(_Target.android),
  );

  test(
    'export exact synthetic core configurations for independent CLI checks',
    () async {
      final output = await Directory(outputDirectory).create(recursive: true);
      for (final target in _Target.values) {
        for (final setting in settings.entries) {
          for (final protocol in protocolLinks.entries) {
            final proxy = const LinkDispatcher().dispatch(protocol.value);
            final name = '${target.name}-${setting.key}-${protocol.key}.json';
            await File(
              '${output.path}/$name',
            ).writeAsString(_configuration(target, proxy, setting.value));
          }
        }
      }
      for (final protocol in ['wireguard', 'amneziawg']) {
        final reservedProxy = const LinkDispatcher().dispatch(
          _protocolLinks(reserved: [0, 0, 0])[protocol]!,
        );
        await File(
          '${output.path}/android-zero-reserved-$protocol.json',
        ).writeAsString(
          _configuration(_Target.android, reservedProxy, const AppSettings()),
        );
      }
      final wg = const LinkDispatcher().dispatch(protocolLinks['wireguard']!);
      await File(
        '${output.path}/android-wireguard-ping.json',
      ).writeAsString(const SingboxConfigGenerator().generateForPing(wg, 9099));
      final tuic = const LinkDispatcher().dispatch(protocolLinks['tuic']!);
      for (final target in _Target.values) {
        await File(
          '${output.path}/${target.name}-tuic-multiplexer.json',
        ).writeAsString(
          _configuration(
            target,
            tuic,
            const AppSettings(multiplexerEnabled: true),
          ),
        );
      }
      final shadowTls = const LinkDispatcher().dispatch(_shadowTlsLink());
      for (final target in _Target.values) {
        final vision = const LinkDispatcher().dispatch(
          protocolLinks['vless-reality']!,
        );
        await File(
          '${output.path}/${target.name}-vision-multiplex.json',
        ).writeAsString(
          _configuration(
            target,
            vision,
            const AppSettings(multiplexerEnabled: true),
          ),
        );
      }
      for (final setting in settings.entries) {
        await File(
          '${output.path}/android-${setting.key}-shadowtls.json',
        ).writeAsString(
          _configuration(_Target.android, shadowTls, setting.value),
        );
      }
      await File('${output.path}/android-shadowtls-ping.json').writeAsString(
        const SingboxConfigGenerator().generateForPing(shadowTls, 9099),
      );
      await File(
        '${output.path}/android-shadowtls-multiplexer.json',
      ).writeAsString(
        _configuration(
          _Target.android,
          shadowTls,
          const AppSettings(multiplexerEnabled: true),
        ),
      );
    },
    skip: outputDirectory.isEmpty
        ? 'CORE_CONFIG_OUTPUT_DIR is not configured'
        : false,
  );

  for (final target in _Target.values) {
    for (final setting in settings.entries) {
      for (final protocol in protocolLinks.entries) {
        final name = '${target.name}-${setting.key}-${protocol.key}';
        test('sing-box accepts $name', () async {
          final proxy = const LinkDispatcher().dispatch(protocol.value);
          final config = File('${scratch!.path}/$name.json');
          await config.writeAsString(
            _configuration(target, proxy, setting.value),
          );
          await _checkCore(_binaryFor(target), config, target);
        }, skip: _skipCoreCheck(target));
      }
    }
  }
}
