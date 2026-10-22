import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscription_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _feed = 'https://provider.example.test/feed';

ParsedProxy _proxy(
  int index, {
  String? name,
}) => const LinkDispatcher().dispatch(
  'vless://account-$index@192.0.2.10:443?security=tls#${name ?? 'Node $index'}',
);

class _DrawRandom implements Random {
  final bounds = <int>[];

  @override
  int nextInt(int max) {
    bounds.add(max);
    return 37 % max;
  }

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

Future<(ProviderContainer, ServersNotifier)> _fixture({Random? random}) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      if (random != null) builtInFreeRandomProvider.overrideWithValue(random),
    ],
  );
  addTearDown(container.dispose);
  await container.read(serversNotifierProvider.future);
  return (container, container.read(serversNotifierProvider.notifier));
}

void main() {
  test(
    'large snapshot keeps identities and queued selection favorite and ping',
    () async {
      final (container, notifier) = await _fixture();
      final proxies = List.generate(80, _proxy);
      await notifier.replaceSubscription(_feed, proxies);
      final original = container.read(serversNotifierProvider).requireValue;
      final favorite = notifier.setFavoriteIfCurrent(original[17], true);
      final latency = notifier.updateLatency(original[17].id, 123);
      final refresh = notifier.replaceSubscription(_feed, [
        ...proxies.reversed,
        proxies[17], // A duplicate cannot allocate a second profile or ID.
      ]);
      final selection = notifier.selectServerIfCurrent(original[29]);
      expect(await favorite, isTrue);
      await Future.wait([latency, refresh]);
      expect(await selection, isTrue);

      final profiles = container.read(serversNotifierProvider).requireValue;
      expect(
        profiles.map((profile) => profile.id),
        original.reversed.map((s) => s.id),
      );
      expect(
        profiles.map((profile) => profile.addedAt),
        original.reversed.map((s) => s.addedAt),
      );
      final retained = profiles.singleWhere((s) => s.id == original[17].id);
      expect(retained.isFavorite, isTrue);
      expect(retained.latencyMs, 123);
      expect(profiles.singleWhere((s) => s.isSelected).id, original[29].id);
      final prefs = await SharedPreferences.getInstance();
      final saved = ServerProfileModel.listFromJson(
        prefs.getString('honeyvpn_servers')!,
      );
      expect(saved.singleWhere((s) => s.isSelected).id, original[29].id);
      expect(saved.singleWhere((s) => s.id == retained.id).isFavorite, isTrue);
    },
  );

  test(
    'large free feed draws once from distinct nodes and rejects stale leases',
    () async {
      final random = _DrawRandom();
      final (container, notifier) = await _fixture(random: random);
      final proxies = List.generate(80, _proxy);
      final lease = await notifier.freeServerSnapshot();
      final replacement = await notifier.replaceSubscriptionSnapshot(
        builtInSubscriptionUrl,
        [...proxies, proxies[37]],
        freeSnapshot: lease,
      );
      expect(replacement.applied, isTrue);
      expect(replacement.count, 1);
      expect(random.bounds, [80]);
      final selected = container
          .read(serversNotifierProvider)
          .requireValue
          .single;
      expect(selected.name, 'Node 37');

      final stale = await notifier.replaceSubscriptionSnapshot(
        builtInSubscriptionUrl,
        proxies,
        freeSnapshot: lease,
      );
      expect(stale.applied, isFalse);
      expect(random.bounds, [80]);
      expect(
        container.read(serversNotifierProvider).requireValue.single.id,
        selected.id,
      );
    },
  );

  test(
    'one large configuration preserves its identity across refresh',
    () async {
      final (container, notifier) = await _fixture();
      final proxy = _proxy(1, name: 'long-name' * 9000);
      await notifier.replaceSubscription(_feed, [proxy]);
      final original = container
          .read(serversNotifierProvider)
          .requireValue
          .single;
      expect(original.configJson.length, greaterThan(64 * 1024));
      await notifier.setFavoriteIfCurrent(original, true);
      await notifier.replaceSubscription(_feed, [proxy]);
      final refreshed = container
          .read(serversNotifierProvider)
          .requireValue
          .single;
      expect(refreshed.id, original.id);
      expect(refreshed.addedAt, original.addedAt);
      expect(refreshed.isFavorite, isTrue);
      expect(refreshed.configJson, original.configJson);
    },
  );
}
