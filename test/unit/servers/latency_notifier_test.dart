import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/servers/data/services/profile_latency_service.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

ParsedProxy _proxy(
  String identity, {
  String host = '192.0.2.10',
  String name = 'Old',
}) => const LinkDispatcher().dispatch(
  'vless://$identity@$host:443?security=tls#$name',
);

class _PendingService implements ProfileLatencyService {
  final pending = <Completer<double>>[];
  final cancellations = <LatencyCancellation>[];
  int active = 0;
  int maxActive = 0;

  @override
  Future<double> measure(
    ParsedProxy proxy, {
    required LatencyCancellation cancellation,
  }) async {
    final result = Completer<double>();
    pending.add(result);
    cancellations.add(cancellation);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      return await Future.any([
        result.future,
        cancellation.whenCancelled.then((_) => -1.0),
      ]);
    } finally {
      active--;
    }
  }
}

Future<(ProviderContainer, ServersNotifier, _PendingService)> _fixture() async {
  SharedPreferences.setMockInitialValues({});
  final service = _PendingService();
  final container = ProviderContainer(
    overrides: [profileLatencyServiceProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  final notifier = container.read(serversNotifierProvider.notifier);
  await container.read(serversNotifierProvider.future);
  return (container, notifier, service);
}

Future<void> _until(bool Function() condition) async {
  final deadline = Stopwatch()..start();
  while (!condition()) {
    if (deadline.elapsed > const Duration(seconds: 3))
      fail('condition timeout');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  test('batch progress joins repeat taps and bounds four workers', () async {
    final (container, notifier, service) = await _fixture();
    await notifier.addFromProxies(
      List.generate(9, (i) => _proxy('account-$i')),
    );
    final first = notifier.testAllLatency();
    final repeated = notifier.testAllLatency();
    await _until(() => service.pending.length == 4);
    var progress = container.read(latencyTestProgressProvider);
    expect(progress.isRunning, true);
    expect(progress.total, 9);
    expect(progress.activeIds, hasLength(4));
    expect(progress.completed, 0);
    for (var i = 0; i < 9; i++) {
      await _until(() => service.pending.length > i);
      service.pending[i].complete(100.0 + i);
    }
    await Future.wait([first, repeated]);
    progress = container.read(latencyTestProgressProvider);
    expect(progress.isRunning, false);
    expect(progress.total, 9);
    expect(progress.completed, 9);
    expect(progress.activeIds, isEmpty);
    expect(service.pending, hasLength(9));
    expect(service.maxActive, 4);
    expect(
      container
          .read(serversNotifierProvider)
          .requireValue
          .map((s) => s.latencyMs),
      [100, 101, 102, 103, 104, 105, 106, 107, 108],
    );
  });

  test(
    'cancel stops new work and preserves completed or previous samples',
    () async {
      final (container, notifier, service) = await _fixture();
      await notifier.addFromProxies(
        List.generate(8, (i) => _proxy('account-$i')),
      );
      final profiles = container.read(serversNotifierProvider).requireValue;
      for (final profile in profiles) {
        await notifier.updateLatency(profile.id, 25);
      }
      final batch = notifier.testAllLatency();
      await _until(() => service.pending.length == 4);
      service.pending.first.complete(123);
      await _until(
        () => container.read(latencyTestProgressProvider).completed == 1,
      );
      await notifier.cancelLatencyTests();
      await batch;
      expect(container.read(latencyTestProgressProvider).isRunning, false);
      expect(container.read(latencyTestProgressProvider).completed, 1);
      expect(service.pending.length, lessThanOrEqualTo(5));
      expect(service.cancellations.where((c) => !c.isCancelled), hasLength(1));
      expect(
        container.read(serversNotifierProvider).requireValue.first.latencyMs,
        123,
      );
      expect(
        container
            .read(serversNotifierProvider)
            .requireValue
            .skip(1)
            .map((s) => s.latencyMs),
        everyElement(25),
      );
    },
  );

  test(
    'old result cannot attach to a refreshed different profile that reused its id',
    () async {
      final (container, notifier, service) = await _fixture();
      await notifier.addFromProxies([
        _proxy('old-account'),
      ], subscriptionId: 'https://example.test/feed');
      final old = container.read(serversNotifierProvider).requireValue.single;
      final probe = notifier.testLatency(old);
      await _until(() => service.pending.isNotEmpty);
      await notifier.replaceSubscription('https://example.test/feed', [
        _proxy('old-account', name: 'Refreshed'),
      ]);
      final fresh = container.read(serversNotifierProvider).requireValue.single;
      expect(fresh.id, old.id);
      service.pending.single.complete(321);
      expect(await probe, 321);
      expect(
        container.read(serversNotifierProvider).requireValue.single.latencyMs,
        null,
      );
    },
  );

  test('deleted profile never reappears after a late result', () async {
    final (container, notifier, service) = await _fixture();
    await notifier.addFromProxy(_proxy('account'));
    final profile = container.read(serversNotifierProvider).requireValue.single;
    final probe = notifier.testLatency(profile);
    await _until(() => service.pending.isNotEmpty);
    await notifier.delete(profile.id);
    service.pending.single.complete(123);
    await probe;
    expect(container.read(serversNotifierProvider).requireValue, isEmpty);
  });

  test(
    'unavailable result replaces stale latency without false success',
    () async {
      final (container, notifier, service) = await _fixture();
      await notifier.addFromProxy(_proxy('account'));
      final profile = container
          .read(serversNotifierProvider)
          .requireValue
          .single;
      await notifier.updateLatency(profile.id, 1);
      final probe = notifier.testLatency(profile);
      await _until(() => service.pending.isNotEmpty);
      service.pending.single.complete(-1);
      expect(await probe, -1);
      expect(
        container.read(serversNotifierProvider).requireValue.single.latencyMs,
        -1,
      );
    },
  );

  test(
    'disposing container cancels native probes without late state publication',
    () async {
      final (container, notifier, service) = await _fixture();
      await notifier.addFromProxy(_proxy('account'));
      final probe = notifier.testLatency(
        container.read(serversNotifierProvider).requireValue.single,
      );
      await _until(() => service.pending.isNotEmpty);
      container.dispose();
      expect(await probe, -1);
      expect(service.cancellations.single.isCancelled, true);
      expect(service.active, 0);
    },
  );
}
