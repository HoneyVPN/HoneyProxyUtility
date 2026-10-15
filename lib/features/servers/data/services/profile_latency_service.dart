import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../../connection/data/singbox/singbox_config_generator.dart';
import '../../../converter/domain/entities/parsed_proxy.dart';

/// This measures an HTTPS response through the profile, not ICMP or a TCP
/// handshake to its listening port. It is a reachability sample, not a promise
/// about sustained throughput or the application's DNS/routing configuration.
abstract interface class ProfileLatencyService {
  Future<double> measure(
    ParsedProxy proxy, {
    required LatencyCancellation cancellation,
  });
}

class LatencyCancellation {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const _CancelledProbe();
  }

  Future<T> race<T>(Future<T> operation) => Future.any([
    operation,
    whenCancelled.then<T>((_) => throw const _CancelledProbe()),
  ]);
}

class _CancelledProbe implements Exception {
  const _CancelledProbe();
}

/// Native ownership survives process exit: Windows retains process/job handles;
/// Android serializes spawning, waitpid and retirement in its native registry.
/// Neither platform gives this child to Dart/Java independent process reapers.
abstract class LatencyOwnedProcess {
  Future<int> get exitCode;
  bool kill({bool force = false});

  Future<bool> stop(Duration timeout) async {
    try {
      kill();
      await exitCode.timeout(timeout);
      return true;
    } catch (_) {
      try {
        kill(force: true);
        await exitCode.timeout(timeout);
        return true;
      } catch (_) {
        return false;
      }
    }
  }
}

class NativeLatencyOwnedProcess extends LatencyOwnedProcess {
  NativeLatencyOwnedProcess._(this.id) {
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _poll());
    unawaited(_poll());
  }

  static const channel = MethodChannel('ru.honeyvpn.proxy/latency');
  final int id;
  final _exit = Completer<int>();
  Timer? _timer;
  bool _polling = false;
  Future<bool>? _stopping;

  static Future<LatencyOwnedProcess> start(
    String configPath,
    String directory,
  ) async {
    final id = await channel.invokeMethod<int>('start', {
      'configPath': configPath,
      'directory': directory,
    });
    if (id == null || id <= 0) throw StateError('Native probe did not start');
    return NativeLatencyOwnedProcess._(id);
  }

  @override
  Future<int> get exitCode => _exit.future;

  Future<void> _poll() async {
    if (_polling || _stopping != null || _exit.isCompleted) return;
    _polling = true;
    try {
      final status = await channel
          .invokeMapMethod<String, dynamic>('status', {'id': id})
          .timeout(const Duration(seconds: 1));
      if (status?['exited'] == true && status?['exitCode'] is int) {
        _exit.complete(status!['exitCode'] as int);
        _timer?.cancel();
      }
    } catch (_) {
      // Lost channel != exit ACK. Stop still requires retained-handle cleanup.
    } finally {
      _polling = false;
    }
  }

  @override
  bool kill({bool force = false}) {
    unawaited(stop(const Duration(seconds: 2)));
    return true;
  }

  @override
  Future<bool> stop(Duration timeout) {
    if (_stopping != null) return _stopping!;
    _timer?.cancel();
    final operation = channel
        .invokeMethod<bool>('stop', {'id': id})
        .timeout(timeout)
        .then((stopped) {
          if (stopped == true && !_exit.isCompleted) _exit.complete(0);
          return stopped == true;
        }, onError: (Object _, StackTrace __) => false);
    _stopping = operation;
    return operation.whenComplete(() => _stopping = null);
  }
}

typedef LatencyProcessLauncher =
    Future<LatencyOwnedProcess> Function(
      String binary,
      String configPath,
      String directory,
    );

class IsolatedCoreLatencyService implements ProfileLatencyService {
  IsolatedCoreLatencyService({
    Future<String?> Function()? resolveBinary,
    Future<Directory> Function()? temporaryDirectory,
    LatencyProcessLauncher? launch,
    bool? windowsRouting,
    this.startupTimeout = const Duration(seconds: 3),
    this.requestTimeout = const Duration(seconds: 6),
    this.cleanupTimeout = const Duration(seconds: 2),
  }) : _resolveBinary = resolveBinary ?? _bundledBinary,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _launch = launch ?? _launchCore,
       _windowsRouting = windowsRouting ?? _defaultWindowsRouting();

  final Future<String?> Function() _resolveBinary;
  final Future<Directory> Function() _temporaryDirectory;
  final LatencyProcessLauncher _launch;
  final bool _windowsRouting;
  final Duration startupTimeout;
  final Duration requestTimeout;
  final Duration cleanupTimeout;
  int _cleanupUnconfirmed = 0;
  int _active = 0;
  final _waiters = <Completer<void>>[];

  static const _channel = MethodChannel('ru.honeyvpn.proxy/native');

  static bool _defaultWindowsRouting() {
    try {
      return Platform.isWindows;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _bundledBinary() async {
    if (Platform.isWindows) {
      return '${File(Platform.resolvedExecutable).parent.path}/sing-box.exe';
    }
    if (Platform.isAndroid) {
      final directory = await _channel.invokeMethod<String>('getNativeLibDir');
      return directory == null ? null : '$directory/libsingbox.so';
    }
    // Apple requires the signed extension; spawning a CLI cannot stand in for
    // it. Unsupported platforms must never fall back to misleading TCP ping.
    return null;
  }

  static Future<LatencyOwnedProcess> _launchCore(
    String binary,
    String configPath,
    String directory,
  ) async {
    if (Platform.isWindows || Platform.isAndroid) {
      return NativeLatencyOwnedProcess.start(configPath, directory);
    }
    throw UnsupportedError('Native latency process is unavailable');
  }

  static String _nonce() => base64Url.encode(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );

  /// No TUN, SOCKS/HTTP inbound, system proxy, routes, geodata downloads or
  /// persistent cache. The selected core's delay endpoint accepts outbounds;
  /// WireGuard/AWG endpoints are deliberately reported as unavailable.
  static String configuration(
    ParsedProxy proxy,
    int apiPort,
    String secret, {
    bool windowsRouting = false,
  }) {
    if (proxy is WireGuardConfig || proxy is AmneziaWGConfig) {
      throw UnsupportedError('Endpoint delay measurement is unavailable');
    }
    final config =
        jsonDecode(
              const SingboxConfigGenerator().generateForPing(proxy, apiPort),
            )
            as Map<String, dynamic>;
    config['inbounds'] = <Object>[];
    config['dns'] = {
      'servers': [
        {'type': 'local', 'tag': 'probe-local'},
      ],
      'final': 'probe-local',
      'strategy': 'prefer_ipv4',
    };
    config['route'] = {
      'default_domain_resolver': 'probe-local',
      // The pinned Windows monitor excludes Wintun/loopback and binds both TCP
      // and UDP sockets to the active physical default interface. Android's
      // executable shares the app UID excluded by VpnService.Builder instead.
      if (windowsRouting) 'auto_detect_interface': true,
    };
    config['experimental'] = {
      'clash_api': {
        'external_controller': '127.0.0.1:$apiPort',
        'secret': secret,
      },
    };
    return jsonEncode(config);
  }

  @override
  Future<double> measure(
    ParsedProxy proxy, {
    required LatencyCancellation cancellation,
  }) async {
    try {
      while (_active >= 4) {
        final waiter = Completer<void>();
        _waiters.add(waiter);
        try {
          await cancellation.race(waiter.future);
        } finally {
          _waiters.remove(waiter);
          if (cancellation.isCancelled && _active < 4) _wakeWaiter();
        }
      }
      cancellation.check();
    } catch (_) {
      return -1;
    }
    _active++;
    try {
      return await _measure(proxy, cancellation: cancellation);
    } finally {
      _active--;
      // One slot becomes available. A cancelled waiter cannot consume it.
      _wakeWaiter();
    }
  }

  void _wakeWaiter() {
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
        break;
      }
    }
  }

  Future<double> _measure(
    ParsedProxy proxy, {
    required LatencyCancellation cancellation,
  }) async {
    if (_cleanupUnconfirmed > 0 || cancellation.isCancelled) return -1;
    Directory? directory;
    LatencyOwnedProcess? process;
    var exited = false;
    var launchAbandoned = false;
    Future<LatencyOwnedProcess>? pendingLaunch;
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500)
      ..findProxy = (_) => 'DIRECT';
    // Close active sockets immediately on cancellation, rather than waiting for
    // the core's delay timeout to finish.
    unawaited(
      cancellation.whenCancelled.then((_) => client.close(force: true)),
    );
    try {
      cancellation.check();
      final secret = _nonce();
      // Reject unsupported profiles before asking native code for its binary
      // directory, reserving a port or preparing a temporary workspace.
      configuration(proxy, 1, secret, windowsRouting: _windowsRouting);
      final binary = await cancellation
          .race(_resolveBinary())
          .timeout(startupTimeout);
      if (binary == null || !await File(binary).exists()) return -1;
      final root = await cancellation
          .race(_temporaryDirectory())
          .timeout(startupTimeout);
      directory = await root.createTemp('honey-latency-');
      cancellation.check();
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final file = File('${directory.path}/config.json');
      await file.writeAsString(
        configuration(proxy, port, secret, windowsRouting: _windowsRouting),
        flush: true,
      );
      cancellation.check();
      pendingLaunch = _launch(binary, file.path, directory.path);
      process = await cancellation.race(pendingLaunch).timeout(startupTimeout);
      unawaited(process.exitCode.then((_) => exited = true));
      final startup = Stopwatch()..start();
      var ready = false;
      while (startup.elapsed < startupTimeout) {
        cancellation.check();
        if (exited) return -1;
        try {
          final denied = await cancellation
              .race(_request(client, port, '/version', _nonce()))
              .timeout(const Duration(milliseconds: 650));
          final version = await cancellation
              .race(_request(client, port, '/version', secret))
              .timeout(const Duration(milliseconds: 650));
          if (denied.$1 != 401) return -1;
          final body = jsonDecode(version.$2);
          if (version.$1 == 200 &&
              body is Map &&
              body['version'] is String &&
              RegExp(
                r'^sing-box \d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.\-]+)?$',
              ).hasMatch(body['version'] as String)) {
            ready = true;
            break;
          }
        } on _CancelledProbe {
          rethrow;
        } catch (_) {}
        await cancellation.race(
          Future<void>.delayed(const Duration(milliseconds: 80)),
        );
      }
      if (!ready || exited) return -1;
      final query = Uri(
        queryParameters: {
          'timeout': '5000',
          'url': 'https://www.gstatic.com/generate_204',
        },
      ).query;
      final response = await cancellation
          .race(_request(client, port, '/proxies/proxy/delay?$query', secret))
          .timeout(requestTimeout);
      cancellation.check();
      if (response.$1 != 200 || exited) return -1;
      final body = jsonDecode(response.$2);
      final delay = body is Map ? body['delay'] : null;
      return delay is num && delay.isFinite && delay > 0 && delay <= 65535
          ? delay.toDouble()
          : -1;
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
      if (pendingLaunch != null && process == null) {
        // A timed-out native start may still complete. Keep its directory and
        // refuse more native probes until its own handle can be retired.
        launchAbandoned = true;
        _cleanupUnconfirmed++;
        final ownDirectory = directory;
        unawaited(
          pendingLaunch.then(
            (late) async {
              if (await _stop(late)) {
                try {
                  await ownDirectory?.delete(recursive: true);
                } catch (_) {}
                _cleanupUnconfirmed--;
              }
            },
            onError: (Object _, StackTrace __) async {
              try {
                await ownDirectory?.delete(recursive: true);
              } catch (_) {}
              _cleanupUnconfirmed--;
            },
          ),
        );
      }
      if (process != null && !await _stop(process)) {
        _cleanupUnconfirmed++;
      } else if (!launchAbandoned) {
        try {
          await directory?.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<bool> _stop(LatencyOwnedProcess process) async {
    return process.stop(cleanupTimeout);
  }

  static Future<(int, String)> _request(
    HttpClient client,
    int port,
    String path,
    String secret,
  ) async {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 4096) {
        throw const FormatException('Oversized core response');
      }
      bytes.addAll(chunk);
    }
    return (response.statusCode, utf8.decode(bytes));
  }
}
