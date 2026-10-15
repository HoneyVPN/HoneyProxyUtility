import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/vpn_datasource_windows.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/vless_parser.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

Map<String, String> get _environment => Map.fromEntries(
  Platform.environment.entries.where(
    (entry) => !entry.key.startsWith('ENABLE_DEPRECATED_'),
  ),
);

Future<int> _unusedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<bool> _apiReady(HttpClient client, int port) async {
  try {
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/version'))
        .timeout(const Duration(seconds: 1));
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer synthetic-regression-nonce',
    );
    final response = await request.close().timeout(const Duration(seconds: 1));
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 1));
    return response.statusCode == 200 &&
        (jsonDecode(body) as Map)['version'].toString().startsWith('sing-box ');
  } catch (_) {
    return false;
  }
}

void main() {
  final binary =
      Platform.environment['SINGBOX_CHECK_TARGET']?.trim() == 'android'
      ? null
      : Platform.environment['SINGBOX_WINDOWS_CHECK_BINARY'] ??
            Platform.environment['SINGBOX_CHECK_BINARY'];
  final geo = {
    for (final name in [
      'ru-blocked.srs',
      'ru-blocked-community.srs',
      're-filter.srs',
      'ru.srs',
    ])
      name: File('assets/geo/$name').absolute.path,
  };
  final datasource = WindowsVpnDatasource(onStatusChanged: (_) {});
  final proxy = const VlessParser().parse(
    'vless://a3482e88-686a-4a58-8126-99c9df64b7bf@node.example.test:443?security=tls&sni=cover.example.test&type=tcp',
  );

  for (final mode in ConnectionMode.values) {
    test(
      'actual core accepts packaged Windows ${mode.name} DNS and routing',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'honey-windows-config-',
        );
        try {
          for (final settings in [
            const AppSettings(),
            const AppSettings(
              dnsPreset: DnsPreset.custom,
              customDnsUrl: 'https://dns.example.test:8443/custom-dns',
            ),
            const AppSettings(
              routingMode: RoutingMode.global,
              dnsPreset: DnsPreset.adguard,
              preferredIpType: IpType.ipv4,
            ),
          ]) {
            final config = datasource.buildConfiguration(
              proxy,
              settings,
              mode: mode,
              geoPaths: geo,
            );
            final file = File('${directory.path}/config.json');
            await file.writeAsString(jsonEncode(config));
            final checked = await Process.run(
              binary!,
              ['check', '--disable-color', '-c', file.path],
              environment: _environment,
              includeParentEnvironment: false,
            ).timeout(const Duration(seconds: 20));
            expect(
              checked.exitCode,
              0,
              reason: 'Synthetic ${mode.name} config: ${checked.stderr}',
            );
          }
        } finally {
          await directory.delete(recursive: true);
        }
      },
      skip: binary == null
          ? 'Set SINGBOX_CHECK_BINARY to test the actual packaged core'
          : false,
    );
  }

  for (final amnezia in [false, true]) {
    test(
      'actual ${amnezia ? 'AWG' : 'WG'} domain peer resolves locally before its first handshake',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'honey-windows-bootstrap-',
        );
        final dns = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final peerSocket = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        var queries = 0;
        final queriedNames = <String>[];
        var handshakes = 0;
        var handshakeAfterDns = true;
        final peerEvents = peerSocket.listen((event) {
          if (event != RawSocketEvent.read) return;
          while (peerSocket.receive() != null) {
            handshakes++;
            if (queries == 0) handshakeAfterDns = false;
          }
        });
        final dnsEvents = dns.listen((event) {
          if (event != RawSocketEvent.read) return;
          Datagram? packet;
          while ((packet = dns.receive()) != null) {
            final data = packet!.data;
            if (data.length < 17 || data[4] != 0 || data[5] != 1) continue;
            var end = 12;
            while (end < data.length && data[end] != 0) {
              end += data[end] + 1;
            }
            end += 5;
            if (end > data.length) continue;
            queries++;
            var labelOffset = 12;
            final labels = <String>[];
            while (labelOffset < end && data[labelOffset] != 0) {
              final length = data[labelOffset++];
              labels.add(
                ascii.decode(data.sublist(labelOffset, labelOffset + length)),
              );
              labelOffset += length;
            }
            queriedNames.add(labels.join('.'));
            final ipv4 = data[end - 4] == 0 && data[end - 3] == 1;
            final answer = <int>[
              data[0],
              data[1],
              0x81,
              0x80,
              0,
              1,
              0,
              ipv4 ? 1 : 0,
              0,
              0,
              0,
              0,
              ...data.sublist(12, end),
              if (ipv4) ...[
                0xc0,
                0x0c,
                0,
                1,
                0,
                1,
                0,
                0,
                0,
                60,
                0,
                4,
                127,
                0,
                0,
                1,
              ],
            ];
            dns.send(answer, packet.address, packet.port);
          }
        });
        Process? core;
        var exited = false;
        final probeClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2);
        final client = HttpClient()
          ..connectionTimeout = const Duration(milliseconds: 500)
          ..findProxy = (_) => 'DIRECT';
        try {
          final privateKey = base64Encode(List.generate(32, (i) => i + 1));
          final publicKey = base64Encode(List.generate(32, (i) => i + 33));
          final ParsedProxy node = amnezia
              ? AmneziaWGConfig(
                  name: 'Synthetic AWG',
                  host: 'bootstrap.example.test',
                  port: peerSocket.port,
                  privateKey: privateKey,
                  publicKey: publicKey,
                  presharedKey: '',
                  addresses: ['10.20.0.2/32'],
                  dns: [],
                  mtu: 1420,
                )
              : WireGuardConfig(
                  name: 'Synthetic WG',
                  host: 'bootstrap.example.test',
                  port: peerSocket.port,
                  privateKey: privateKey,
                  publicKey: publicKey,
                  presharedKey: '',
                  addresses: ['10.20.0.2/32'],
                  dns: [],
                  mtu: 1420,
                );
          final apiPort = await _unusedPort();
          final socksPort = await _unusedPort();
          var httpPort = await _unusedPort();
          while (httpPort == socksPort || httpPort == apiPort) {
            httpPort = await _unusedPort();
          }
          final config = datasource.buildConfiguration(
            node,
            AppSettings(
              routingMode: RoutingMode.global,
              socksPort: socksPort,
              httpPort: httpPort,
            ),
            mode: ConnectionMode.proxy,
            geoPaths: geo,
          );
          expect((config['endpoints'] as List).first['domain_resolver'], {
            'server': 'local',
            'strategy': 'prefer_ipv4',
          });
          config['dns']['servers'] = [
            {
              'tag': 'remote',
              'type': 'https',
              'server': '127.0.0.1',
              'server_port': 1,
              'path': '/dns-query',
              'domain_resolver': {'server': 'local', 'strategy': 'prefer_ipv4'},
              'detour': 'proxy',
            },
            {
              'tag': 'local',
              'type': 'udp',
              'server': '127.0.0.1',
              'server_port': dns.port,
              'detour': 'direct',
            },
          ];
          // First traffic now triggers lazy peer DNS in the newer core. Route
          // this synthetic inner request only through WG, never a direct/private
          // exception; its sole outer peer and DNS server are bound loopback.
          config['route']['rules'] = <Object>[];
          expect(config['route']['auto_detect_interface'], isTrue);
          // Production binds WG UDP to the physical default interface. Windows
          // cannot deliver that socket to this fixture's 127.0.0.1 fake peer.
          // Disable binding only for the isolated loopback DNS/handshake proof;
          // packaged configurations with the production flag are checked above.
          config['route']['auto_detect_interface'] = false;
          probeClient.findProxy = (_) => 'PROXY 127.0.0.1:$httpPort';
          config['experimental']['clash_api'] = {
            'external_controller': '127.0.0.1:$apiPort',
            'secret': 'synthetic-regression-nonce',
          };
          final file = File('${directory.path}/config.json');
          await file.writeAsString(jsonEncode(config));
          core = await Process.start(
            binary!,
            ['run', '--disable-color', '-c', file.path],
            environment: _environment,
            includeParentEnvironment: false,
          );
          final stdout = core.stdout.transform(utf8.decoder).join();
          final stderr = core.stderr.transform(utf8.decoder).join();
          unawaited(
            core.exitCode.then((_) {
              exited = true;
            }),
          );
          final watch = Stopwatch()..start();
          var ready = false;
          while (!exited && watch.elapsed < const Duration(seconds: 10)) {
            if (await _apiReady(client, apiPort)) {
              ready = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          Future<void>? probe;
          if (ready && !exited) {
            probe = () async {
              try {
                final request = await probeClient
                    .getUrl(Uri.parse('http://192.0.2.1/fixture'))
                    .timeout(const Duration(seconds: 3));
                final response = await request.close().timeout(
                  const Duration(seconds: 3),
                );
                await response.drain<void>().timeout(
                  const Duration(seconds: 3),
                );
              } catch (_) {
                // The fake WG peer only captures a handshake, without replying.
              }
            }();
            watch.reset();
            while (!exited &&
                watch.elapsed < const Duration(seconds: 5) &&
                (queries == 0 || handshakes == 0)) {
              await Future<void>.delayed(const Duration(milliseconds: 25));
            }
          }
          probeClient.close(force: true);
          if (probe != null) await probe;
          if (!exited) core.kill();
          await core.exitCode.timeout(const Duration(seconds: 5));
          final diagnostics = await Future.wait([stdout, stderr]);
          expect(
            ready,
            isTrue,
            reason: 'Synthetic loopback bootstrap: $diagnostics',
          );
          expect(
            queries,
            greaterThan(0),
            reason:
                'Domain peer must query the direct local resolver before its first handshake',
          );
          expect(
            queriedNames,
            contains('bootstrap.example.test'),
            reason: 'Only the synthetic peer domain requires bootstrap DNS',
          );
          expect(
            handshakes,
            greaterThan(0),
            reason:
                'First proxy traffic must initiate the local fake peer handshake: $diagnostics',
          );
          expect(
            handshakeAfterDns,
            isTrue,
            reason:
                'Peer endpoint is resolved before sending its first handshake',
          );
        } finally {
          client.close(force: true);
          probeClient.close(force: true);
          if (core != null && !exited) {
            core.kill();
            await core.exitCode.timeout(const Duration(seconds: 5));
          }
          await dnsEvents.cancel();
          dns.close();
          await peerEvents.cancel();
          peerSocket.close();
          await directory.delete(recursive: true);
        }
      },
      skip: binary == null
          ? 'Set SINGBOX_CHECK_BINARY to test actual endpoint bootstrap'
          : false,
    );
  }

  test(
    'actual proxy startup needs no rule-set download and owns its API',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'honey-windows-local-start-',
      );
      Process? core;
      final client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 500)
        ..findProxy = (_) => 'DIRECT';
      try {
        final apiPort = await _unusedPort();
        final settings = AppSettings(
          socksPort: await _unusedPort(),
          httpPort: await _unusedPort(),
        );
        final config = datasource.buildConfiguration(
          proxy,
          settings,
          mode: ConnectionMode.proxy,
          geoPaths: geo,
        );
        config['experimental']['clash_api'] = {
          'external_controller': '127.0.0.1:$apiPort',
          'secret': 'synthetic-regression-nonce',
        };
        expect(
          (config['route']['rule_set'] as List).every(
            (r) => r['type'] == 'local' && !r.containsKey('url'),
          ),
          isTrue,
        );
        final file = File('${directory.path}/config.json');
        await file.writeAsString(jsonEncode(config));
        final watch = Stopwatch()..start();
        core = await Process.start(
          binary!,
          ['run', '--disable-color', '-c', file.path],
          environment: _environment,
          includeParentEnvironment: false,
        );
        final stdout = core.stdout.transform(utf8.decoder).join();
        final stderr = core.stderr.transform(utf8.decoder).join();
        final exited = core.exitCode;
        int? exitCode;
        unawaited(
          exited.then((code) {
            exitCode = code;
          }),
        );
        bool ready = false;
        while (watch.elapsed < const Duration(seconds: 10) &&
            exitCode == null) {
          try {
            final request = await client
                .getUrl(Uri.parse('http://127.0.0.1:$apiPort/version'))
                .timeout(const Duration(seconds: 1));
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer synthetic-regression-nonce',
            );
            final response = await request.close().timeout(
              const Duration(seconds: 1),
            );
            final body = await response
                .transform(utf8.decoder)
                .join()
                .timeout(const Duration(seconds: 1));
            ready =
                response.statusCode == 200 &&
                (jsonDecode(body) as Map)['version'].toString().startsWith(
                  'sing-box ',
                );
            if (ready) break;
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (!ready) {
          core.kill();
          await exited.timeout(const Duration(seconds: 5));
          fail(
            'Synthetic local startup did not become ready: ${await stderr}; ${await stdout}',
          );
        }
        final foreign = await client.getUrl(
          Uri.parse('http://127.0.0.1:$apiPort/version'),
        );
        foreign.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer wrong-regression-nonce',
        );
        final response = await foreign.close().timeout(
          const Duration(seconds: 2),
        );
        await response.drain<void>();
        expect(response.statusCode, 401);
        core.kill();
        await exited.timeout(const Duration(seconds: 5));
        await Future.wait([stdout, stderr]);
      } finally {
        client.close(force: true);
        core?.kill();
        await directory.delete(recursive: true);
      }
    },
    skip: binary == null
        ? 'Set SINGBOX_CHECK_BINARY to test loopback-only startup'
        : false,
  );
}
