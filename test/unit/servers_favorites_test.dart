import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/converter/data/parsers/link_dispatcher.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/data/services/profile_latency_service.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/subscriptions/data/services/subscription_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const _feed = 'https://provider.example.test/subscription';
const _otherFeed = 'https://other.example.test/subscription';

ParsedProxy _proxy(
  String account, {
  String name = 'Finland',
}) => const LinkDispatcher().dispatch(
  'vless://$account@192.0.2.10:443?security=tls#${Uri.encodeComponent(name)}',
);

class _DrawRandom implements Random {
  _DrawRandom(this.draws);
  final List<int> draws;
  var index = 0;

  @override
  int nextInt(int max) => draws[(index++) % draws.length] % max;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

class _PendingLatency implements ProfileLatencyService {
  final started = Completer<void>();
  final result = Completer<double>();

  @override
  Future<double> measure(
    ParsedProxy proxy, {
    required LatencyCancellation cancellation,
  }) {
    started.complete();
    return Future.any([
      result.future,
      cancellation.whenCancelled.then((_) => -1.0),
    ]);
  }
}

class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore(super.data) : super.withData();

  var rejectWrites = false;
  int? rejectedWritesRemaining;
  Object? writeFailure;
  Object? reloadFailure;
  var reloadCalls = 0;
  final writes = <String>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(key);
    // Windows mutates its backend cache before attempting the disk write.
    await super.setValue(valueType, key, value);
    if (key == 'flutter.honeyvpn_servers' &&
        rejectedWritesRemaining != 0 &&
        (writeFailure != null || rejectWrites)) {
      if (rejectedWritesRemaining != null)
        rejectedWritesRemaining = rejectedWritesRemaining! - 1;
      if (writeFailure != null) throw writeFailure!;
      return false;
    }
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() {
    reloadCalls++;
    if (reloadFailure != null) {
      return Future<Map<String, Object>>.error(reloadFailure!);
    }
    return super.getAll();
  }
}

Future<_FailingStore> _installFailingStore() async {
  final store = _FailingStore(
    await SharedPreferencesStorePlatform.instance.getAll(),
  );
  SharedPreferencesStorePlatform.instance = store;
  return store;
}

class _Fixture {
  _Fixture(this.container);
  final ProviderContainer container;
  var _disposed = false;

  ServersNotifier get notifier =>
      container.read(serversNotifierProvider.notifier);
  List<ServerProfileModel> get profiles =>
      container.read(serversNotifierProvider).requireValue;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
  }
}

Future<_Fixture> _fixture({
  Map<String, Object>? storage = const {},
  ProfileLatencyService? latency,
  Random? random,
}) async {
  if (storage != null) SharedPreferences.setMockInitialValues(storage);
  final fixture = _Fixture(
    ProviderContainer(
      overrides: [
        if (latency != null)
          profileLatencyServiceProvider.overrideWithValue(latency),
        if (random != null) builtInFreeRandomProvider.overrideWithValue(random),
      ],
    ),
  );
  addTearDown(fixture.dispose);
  await fixture.container.read(serversNotifierProvider.future);
  return fixture;
}

ServerProfileModel _stored({
  int id = 42,
  String source = _feed,
  String account = 'account',
  DateTime? addedAt,
}) => ServerProfileModel(
  id: id,
  protocol: 'vless',
  name: 'Finland',
  host: '192.0.2.10',
  port: 443,
  configJson: jsonEncode({
    'rawLink': 'vless://$account@192.0.2.10:443?security=tls#Finland',
  }),
  subscriptionId: source,
  addedAt: addedAt ?? DateTime.utc(2026, 10, 1),
);

void main() {
  test(
    'favorite persists across reload without changing selection or order',
    () async {
      final fixture = await _fixture();
      await fixture.notifier.addFromProxies([
        _proxy('first'),
        _proxy('second'),
      ]);
      final original = fixture.profiles;
      await fixture.notifier.selectServer(original.first);
      await fixture.notifier.updateLatency(original.last.id, 125);

      expect(
        await fixture.notifier.setFavoriteIfCurrent(original.last, true),
        isTrue,
      );
      // Repeated explicit assignment must not toggle the flag back off.
      expect(
        await fixture.notifier.setFavoriteIfCurrent(original.last, true),
        isTrue,
      );
      expect(
        fixture.profiles.map((profile) => profile.id),
        original.map((p) => p.id),
      );
      expect(fixture.profiles.first.isSelected, isTrue);
      expect(fixture.profiles.last.isSelected, isFalse);
      expect(fixture.profiles.last.latencyMs, 125);
      fixture.dispose();

      final reloaded = await _fixture(storage: null);
      expect(
        reloaded.profiles.map((profile) => profile.id),
        original.map((p) => p.id),
      );
      expect(reloaded.profiles.first.isSelected, isTrue);
      expect(reloaded.profiles.last.isFavorite, isTrue);
      expect(reloaded.profiles.last.latencyMs, isNull);
      expect(
        await reloaded.notifier.setFavoriteIfCurrent(
          reloaded.profiles.last,
          false,
        ),
        isTrue,
      );
      reloaded.dispose();
      final removed = await _fixture(storage: null);
      expect(removed.profiles.last.isFavorite, isFalse);
      expect(removed.profiles.first.isSelected, isTrue);
    },
  );

  test(
    'same connection keeps favorite after provider rename and app reload',
    () async {
      final fixture = await _fixture();
      await fixture.notifier.replaceSubscription(_feed, [_proxy('account')]);
      final original = fixture.profiles.single;
      await fixture.notifier.selectServer(original);
      await fixture.notifier.setFavoriteIfCurrent(original, true);
      await fixture.notifier.replaceSubscription(_feed, [
        _proxy('account', name: 'Finland 2'),
      ]);
      final updated = fixture.profiles.single;
      expect(updated.id, original.id);
      expect(updated.addedAt, original.addedAt);
      expect(updated.name, 'Finland 2');
      expect(updated.isFavorite, isTrue);
      expect(updated.isSelected, isTrue);
      // The old menu must not modify the refreshed raw configuration.
      expect(
        await fixture.notifier.setFavoriteIfCurrent(original, false),
        isFalse,
      );
      expect(fixture.profiles.single.isFavorite, isTrue);
      fixture.dispose();
      final reloaded = await _fixture(storage: null);
      expect(reloaded.profiles.single.isFavorite, isTrue);
      expect(reloaded.profiles.single.isSelected, isTrue);
      expect(reloaded.profiles.single.name, 'Finland 2');
    },
  );

  for (final failureMode in ['false', 'throw']) {
    test(
      'provider recreation keeps committed favorite after failed mutable backend write and restoration $failureMode',
      () async {
        final original = _stored().copyWith(isSelected: true);
        final fixture = await _fixture(
          storage: {
            'honeyvpn_servers': ServerProfileModel.listToJson([original]),
          },
        );
        final store = await _installFailingStore();
        final originalFailure = StateError('Synthetic platform write failure');
        store.rejectWrites = failureMode == 'false';
        store.writeFailure = failureMode == 'throw' ? originalFailure : null;
        await expectLater(
          fixture.notifier.setFavoriteIfCurrent(original, true),
          throwsA(
            failureMode == 'throw'
                ? same(originalFailure)
                : isA<StateError>().having(
                    (error) => error.message,
                    'message',
                    'Failed to save server profiles',
                  ),
          ),
        );
        expect(store.reloadCalls, 0);
        expect(fixture.profiles.single.isFavorite, isFalse);
        expect(fixture.profiles.single.isSelected, isTrue);
        final prefs = await SharedPreferences.getInstance();
        final cached = ServerProfileModel.listFromJson(
          prefs.getString('honeyvpn_servers')!,
        ).single;
        // Both cache layers are restored even when the best-effort restoration
        // also fails. This checks known cache values, not physical disk recovery.
        expect(cached.isFavorite, isFalse);
        expect(cached.isSelected, isTrue);
        expect(store.writes, [
          'flutter.honeyvpn_servers',
          'flutter.honeyvpn_servers',
        ]);
        fixture.dispose();
        final reloaded = await _fixture(storage: null);
        expect(store.reloadCalls, 1);
        expect(reloaded.profiles.single.isFavorite, isFalse);
        expect(reloaded.profiles.single.isSelected, isTrue);
        store.rejectWrites = false;
        store.writeFailure = null;
        expect(
          await reloaded.notifier.setFavoriteIfCurrent(
            reloaded.profiles.single,
            true,
          ),
          isTrue,
        );
        expect(reloaded.profiles.single.isFavorite, isTrue);
        expect(reloaded.profiles.single.isSelected, isTrue);
        final persisted = ServerProfileModel.listFromJson(
          (await store.getAll())['flutter.honeyvpn_servers']! as String,
        ).single;
        expect(persisted.isFavorite, isTrue);
        expect(persisted.isSelected, isTrue);
      },
    );
  }

  for (final failureMode in ['false', 'throw']) {
    test(
      'queued selection keeps committed favorite after failed mutable save/restore $failureMode',
      () async {
        final fixture = await _fixture(
          storage: {
            'honeyvpn_servers': ServerProfileModel.listToJson([
              _stored().copyWith(isSelected: true),
              _stored(id: 2).copyWith(isSelected: false),
            ]),
            'unrelated': 'retained',
          },
        );
        final expected = fixture.profiles.last;
        final store = (await _installFailingStore())
          ..rejectedWritesRemaining = 2
          ..rejectWrites = failureMode == 'false'
          ..writeFailure = failureMode == 'throw'
              ? StateError('Synthetic failure')
              : null;
        final rejected = expectLater(
          fixture.notifier.setFavoriteIfCurrent(expected, true),
          throwsStateError,
        );
        final selected = fixture.notifier.selectServerIfCurrent(expected);
        await rejected;
        expect(await selected, isTrue);
        expect(fixture.profiles.last.isSelected, isTrue);
        expect(fixture.profiles.last.isFavorite, isFalse);
        expect(store.writes, List.filled(3, 'flutter.honeyvpn_servers'));
        fixture.dispose();
        final reloaded = await _fixture(storage: null);
        expect(reloaded.profiles.last.isSelected, isTrue);
        expect(reloaded.profiles.last.isFavorite, isFalse);
        expect(
          (await SharedPreferences.getInstance()).getString('unrelated'),
          'retained',
        );
      },
    );
  }

  test(
    'initial reload failure surfaces without replacing or writing saved profiles',
    () async {
      final original = _stored().copyWith(isSelected: true);
      final fixture = await _fixture(
        storage: {
          'honeyvpn_servers': ServerProfileModel.listToJson([original]),
        },
      );
      final store = await _installFailingStore();
      final readFailure = StateError('Synthetic reload failure');
      store.reloadFailure = readFailure;
      fixture.dispose();
      final failedContainer = ProviderContainer();
      addTearDown(failedContainer.dispose);
      await expectLater(
        failedContainer.read(serversNotifierProvider.future),
        throwsA(same(readFailure)),
      );
      expect(store.reloadCalls, 1);
      expect(failedContainer.read(serversNotifierProvider).hasError, isTrue);
      expect(
        failedContainer.read(serversNotifierProvider).error,
        same(readFailure),
      );
      expect(store.writes, isEmpty);
      store.reloadFailure = null;
      final persisted = ServerProfileModel.listFromJson(
        (await store.getAll())['flutter.honeyvpn_servers']! as String,
      ).single;
      expect(persisted.isFavorite, isFalse);
      expect(persisted.isSelected, isTrue);
      final healthy = await _fixture(storage: null);
      expect(healthy.profiles.single.isFavorite, isFalse);
      expect(healthy.profiles.single.isSelected, isTrue);
      expect(
        await healthy.notifier.setFavoriteIfCurrent(original, true),
        isTrue,
      );
    },
  );

  test(
    'queued favorite, selection, latency and refresh retain each change',
    () async {
      final fixture = await _fixture();
      await fixture.notifier.replaceSubscription(_feed, [
        _proxy('first'),
        _proxy('second'),
      ]);
      final original = fixture.profiles;
      final favorite = fixture.notifier.setFavoriteIfCurrent(
        original.last,
        true,
      );
      final selected = fixture.notifier.selectServerIfCurrent(original.first);
      final latency = fixture.notifier.updateLatency(original.last.id, 77);
      final refresh = fixture.notifier.replaceSubscription(_feed, [
        _proxy('second', name: 'Renamed'),
        _proxy('first'),
      ]);
      expect(await favorite, isTrue);
      expect(await selected, isTrue);
      await Future.wait([latency, refresh]);
      final current = fixture.profiles;
      expect(current.map((profile) => profile.id), [
        original.last.id,
        original.first.id,
      ]);
      expect(current.first.isFavorite, isTrue);
      expect(current.first.latencyMs, 77);
      expect(
        current.where((profile) => profile.isSelected).single.id,
        original.first.id,
      );
      final prefs = await SharedPreferences.getInstance();
      final persisted = ServerProfileModel.listFromJson(
        prefs.getString('honeyvpn_servers')!,
      );
      expect(persisted.first.isFavorite, isTrue);
      expect(persisted.first.latencyMs, 77);
      expect(persisted.last.isSelected, isTrue);
    },
  );

  test(
    'favorite change does not retire an in-flight latency measurement',
    () async {
      final service = _PendingLatency();
      final fixture = await _fixture(latency: service);
      await fixture.notifier.addFromProxy(_proxy('account'));
      final original = fixture.profiles.single;
      final probe = fixture.notifier.testLatency(original);
      await service.started.future;
      await fixture.notifier.setFavoriteIfCurrent(original, true);
      await fixture.notifier.selectServerIfCurrent(original);
      service.result.complete(213);
      expect(await probe, 213);
      expect(fixture.profiles.single.isFavorite, isTrue);
      expect(fixture.profiles.single.isSelected, isTrue);
      expect(fixture.profiles.single.latencyMs, 213);
    },
  );

  test(
    'provider removal does not transfer favorite to a replacement',
    () async {
      final fixture = await _fixture();
      await fixture.notifier.replaceSubscription(_feed, [_proxy('removed')]);
      final old = fixture.profiles.single;
      await fixture.notifier.setFavoriteIfCurrent(old, true);
      await fixture.notifier.replaceSubscription(_feed, [
        _proxy('replacement'),
      ]);
      expect(fixture.profiles.single.id, isNot(old.id));
      expect(fixture.profiles.single.isFavorite, isFalse);
      expect(await fixture.notifier.setFavoriteIfCurrent(old, true), isFalse);
      expect(fixture.profiles, hasLength(1));
      expect(fixture.profiles.single.isFavorite, isFalse);
    },
  );

  for (final (description, replacement) in [
    ('different subscription', _stored(source: _otherFeed)),
    ('different raw configuration', _stored(account: 'replacement')),
    ('recreated connection', _stored(addedAt: DateTime.utc(2026, 10, 2))),
  ]) {
    test('stale menu rejects reused ID with $description', () async {
      final expected = _stored();
      final fixture = await _fixture(
        storage: {
          'honeyvpn_servers': ServerProfileModel.listToJson([replacement]),
        },
      );
      expect(fixture.profiles.single.id, expected.id);
      expect(
        await fixture.notifier.setFavoriteIfCurrent(expected, true),
        isFalse,
      );
      expect(fixture.profiles.single.isFavorite, isFalse);
      expect(fixture.profiles.single.configJson, replacement.configJson);
      expect(
        fixture.profiles.single.subscriptionId,
        replacement.subscriptionId,
      );
      expect(fixture.profiles.single.addedAt, replacement.addedAt);
    });
  }

  test(
    'deleted favorite cannot be resurrected by a late menu action',
    () async {
      final fixture = await _fixture();
      await fixture.notifier.addFromProxy(_proxy('account'));
      final original = fixture.profiles.single;
      await fixture.notifier.setFavoriteIfCurrent(original, true);
      await fixture.notifier.delete(original.id);
      expect(
        await fixture.notifier.setFavoriteIfCurrent(original, true),
        isFalse,
      );
      expect(fixture.profiles, isEmpty);
      fixture.dispose();
      final reloaded = await _fixture(storage: null);
      expect(reloaded.profiles, isEmpty);
    },
  );

  test(
    'favorite does not duplicate, pin or restore the one free server',
    () async {
      final fixture = await _fixture(random: _DrawRandom([0, 1, 0]));
      final candidates = [_proxy('first'), _proxy('second'), _proxy('third')];
      await fixture.notifier.replaceSubscription(
        builtInSubscriptionUrl,
        candidates,
      );
      final original = fixture.profiles.single;
      await fixture.notifier.setFavoriteIfCurrent(original, true);
      await fixture.notifier.replaceSubscription(
        builtInSubscriptionUrl,
        candidates,
      );
      final rotated = fixture.profiles.single;
      expect(rotated.id, isNot(original.id));
      expect(rotated.isFavorite, isFalse);
      expect(fixture.profiles, hasLength(1));
      expect(
        await fixture.notifier.setFavoriteIfCurrent(original, true),
        isFalse,
      );
      await fixture.notifier.setFavoriteIfCurrent(rotated, true);
      await fixture.notifier.delete(
        rotated.id,
        expectedSubscriptionId: builtInSubscriptionUrl,
      );
      expect(
        await fixture.notifier.setFavoriteIfCurrent(rotated, true),
        isFalse,
      );
      final refreshed = await fixture.notifier.replaceSubscriptionSnapshot(
        builtInSubscriptionUrl,
        candidates,
      );
      expect(refreshed.applied, isFalse);
      expect(refreshed.count, 0);
      expect(fixture.profiles, isEmpty);
      expect((await fixture.notifier.freeServerSnapshot()).removed, isTrue);
      fixture.dispose();
      final reloaded = await _fixture(storage: null);
      expect(reloaded.profiles, isEmpty);
      expect((await reloaded.notifier.freeServerSnapshot()).removed, isTrue);
    },
  );
}
