import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:honeyproxyutility/features/connection/data/datasources/singbox_datasource.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/connection_state.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/vpn_core_status.dart';
import 'package:honeyproxyutility/features/connection/presentation/notifiers/connection_notifier.dart';
import 'package:honeyproxyutility/features/converter/domain/entities/parsed_proxy.dart';
import 'package:honeyproxyutility/features/servers/data/models/server_profile_model.dart';
import 'package:honeyproxyutility/features/servers/presentation/notifiers/servers_notifier.dart';
import 'package:honeyproxyutility/features/settings/data/models/app_settings.dart';

const _sessionA = '11111111-1111-4111-8111-111111111111';
const _sessionB = '22222222-2222-4222-8222-222222222222';

VpnCoreStatus _native(
  String state, {
  int? profileId = 1,
  String? sessionId = _sessionA,
}) => VpnCoreStatus(
  state: state,
  usesNativeSessionIdentity: true,
  profileId: profileId,
  sessionId: sessionId,
  trafficAvailable: false,
  ratesAvailable: false,
);

ServerProfileModel _profile(
  int id, {
  bool selected = false,
}) => ServerProfileModel(
  id: id,
  name: 'Synthetic server $id',
  protocol: 'vless',
  host: 'server-$id.example.invalid',
  port: 443,
  isSelected: selected,
  configJson: jsonEncode({
    'rawLink':
        'vless://11111111-1111-4111-8111-111111111111@server-$id.example.invalid:443?security=none&type=tcp#Synthetic',
  }),
  subscriptionId: '',
  addedAt: DateTime(2026),
);

class _Profiles extends ServersNotifier {
  _Profiles(this.result);
  final Future<List<ServerProfileModel>> result;
  @override
  Future<List<ServerProfileModel>> build() => result;
}

class _Source extends VpnDatasource {
  _Source({Future<VpnCoreStatus?>? snapshot})
    : snapshot = snapshot ?? Future.value(null),
      super(onStatusChanged: (_) {}, platform: VpnPlatform.unsupported);
  final Future<VpnCoreStatus?> snapshot;
  void Function(VpnCoreStatus)? status;
  var reattachments = 0;
  var starts = 0;
  var stops = 0;
  var disposed = false;
  int? boundProfile;
  Object? stopError;
  final calls = <String>[];

  @override
  bool get requiresNativeSessionDiscovery => true;

  @override
  Future<VpnCoreStatus?> readCurrentStatus() {
    calls.add('getStatus');
    return snapshot;
  }

  @override
  Future<bool> checkRunning() async => false;
  @override
  void reattach() => reattachments++;
  @override
  void bindProfile(int profileId) {
    super.bindProfile(profileId);
    boundProfile = profileId;
    calls.add('bind:$profileId');
  }

  @override
  Future<void> initialize() async => calls.add('initialize');
  @override
  Future<bool> requestPermission() async {
    calls.add('permission');
    return true;
  }

  @override
  Future<void> start(
    ParsedProxy proxy, {
    ConnectionMode mode = ConnectionMode.tunnel,
    AppSettings settings = const AppSettings(),
  }) async {
    calls.add('start');
    starts++;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (stopError != null) throw stopError!;
  }

  @override
  void dispose() => disposed = true;
}

class _Fixture {
  _Fixture(this.container);
  final ProviderContainer container;
  ConnectionNotifier get notifier =>
      container.read(connectionNotifierProvider.notifier);
  NexConnectionState get state => container.read(connectionNotifierProvider);
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<_Fixture> _fixture(
  List<_Source> sources, {
  Future<List<ServerProfileModel>>? profiles,
}) async {
  SharedPreferences.setMockInitialValues({
    'honeyvpn_settings': const AppSettings(locale: 'en').toJsonString(),
  });
  var index = 0;
  final fixture = _Fixture(
    ProviderContainer(
      overrides: [
        serversNotifierProvider.overrideWith(
          () => _Profiles(
            profiles ??
                Future.value([_profile(1), _profile(2, selected: true)]),
          ),
        ),
        vpnDatasourceFactoryProvider.overrideWithValue(({
          required void Function(VpnCoreStatus) onStatusChanged,
          void Function(String)? onError,
        }) {
          final source = sources[index++];
          source.status = onStatusChanged;
          return source;
        }),
      ],
    ),
  );
  addTearDown(fixture.container.dispose);
  fixture.container.read(connectionNotifierProvider);
  await _settle();
  return fixture;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reopen restores native profile instead of the saved selected profile',
    () async {
      final source = _Source(snapshot: Future.value(_native('CONNECTED')));
      final fixture = await _fixture([source]);
      expect(fixture.state.status, ConnectionStatus.connected);
      expect(fixture.state.activeServer?.id, 1);
      expect(fixture.container.read(selectedServerProvider)?.id, 2);
      expect(fixture.state.nativeProfileId, 1);
      expect(fixture.state.nativeSessionId, _sessionA);
      expect(fixture.state.usesNativeSessionIdentity, isTrue);
      expect(fixture.state.stats.ratesAvailable, isFalse);
      expect(source.calls, ['getStatus']);
      expect(source.reattachments, 1);
      expect(source.starts, 0);
    },
  );

  test('native profile resolves after saved profiles finish loading', () async {
    final profiles = Completer<List<ServerProfileModel>>();
    final source = _Source(snapshot: Future.value(_native('CONNECTED')));
    final fixture = await _fixture([source], profiles: profiles.future);
    expect(fixture.state.status, ConnectionStatus.connected);
    expect(fixture.state.activeServer, isNull);
    expect(fixture.state.nativeProfileId, 1);
    profiles.complete([_profile(1), _profile(2, selected: true)]);
    await _settle();
    expect(fixture.state.activeServer?.id, 1);
    expect(fixture.container.read(selectedServerProvider)?.id, 2);
  });

  test(
    'deleted or absent native identity never borrows saved selection',
    () async {
      final source = _Source(
        snapshot: Future.value(_native('CONNECTED', profileId: 99)),
      );
      final fixture = await _fixture([source]);
      expect(fixture.state.status, ConnectionStatus.connected);
      expect(fixture.state.activeServer, isNull);
      expect(fixture.state.nativeProfileId, 99);
      expect(fixture.container.read(selectedServerProvider)?.id, 2);
      source.status!(_native('CONNECTED', profileId: null, sessionId: null));
      await _settle();
      expect(fixture.state.activeServer, isNull);
      expect(fixture.state.nativeProfileId, isNull);
      expect(fixture.state.usesNativeSessionIdentity, isTrue);
    },
  );

  for (final transitional in ['CONNECTING', 'DISCONNECTING']) {
    test(
      'reopen adopts actual $transitional state without allowing a new start',
      () async {
        final snapshot = Completer<VpnCoreStatus?>();
        final source = _Source(snapshot: snapshot.future);
        final fixture = await _fixture([source]);
        final queuedConnect = fixture.notifier.connect(_profile(2));
        snapshot.complete(
          _native(transitional, profileId: null, sessionId: null),
        );
        await queuedConnect;
        expect(
          fixture.state.status,
          transitional == 'CONNECTING'
              ? ConnectionStatus.connecting
              : ConnectionStatus.disconnecting,
        );
        expect(fixture.state.activeServer, isNull);
        expect(fixture.state.usesNativeSessionIdentity, isTrue);
        expect(fixture.state.isBusy, isTrue);
        expect(source.reattachments, 1);
        await fixture.notifier.connect(_profile(2, selected: true));
        expect(source.starts, 0);
        expect(source.calls, ['getStatus']);
        if (transitional == 'CONNECTING') {
          source.status!(_native('CONNECTED'));
          await _settle();
          expect(fixture.state.status, ConnectionStatus.connected);
          expect(fixture.state.activeServer?.id, 1);
        } else {
          source.status!(
            _native('DISCONNECTED', profileId: null, sessionId: null),
          );
          await _settle();
          expect(fixture.state.status, ConnectionStatus.disconnected);
          expect(fixture.state.activeServer, isNull);
        }
      },
    );
  }

  test('stopped native session cancels a delayed profile lookup', () async {
    final profiles = Completer<List<ServerProfileModel>>();
    final source = _Source(snapshot: Future.value(_native('CONNECTED')));
    final fixture = await _fixture([source], profiles: profiles.future);
    source.status!(_native('DISCONNECTED', profileId: null, sessionId: null));
    profiles.complete([_profile(1), _profile(2, selected: true)]);
    await _settle();
    expect(fixture.state.status, ConnectionStatus.disconnected);
    expect(fixture.state.activeServer, isNull);
    expect(fixture.state.usesNativeSessionIdentity, isFalse);
    expect(source.disposed, isTrue);
    expect(source.stops, 0);
  });

  test(
    'connect waits for late discovery before switching the actual session',
    () async {
      final snapshot = Completer<VpnCoreStatus?>();
      final source = _Source(snapshot: snapshot.future);
      final current = _Source();
      final fixture = await _fixture([source, current]);
      final connect = fixture.notifier.connect(_profile(2, selected: true));
      await _settle();
      expect(current.starts, 0);
      expect(source.stops, 0);
      snapshot.complete(_native('CONNECTED'));
      await connect;
      current.status!(_native('CONNECTED', profileId: 2, sessionId: _sessionB));
      await _settle();
      expect(source.disposed, isTrue);
      expect(source.reattachments, 1);
      expect(source.stops, 1);
      expect(fixture.state.activeServer?.id, 2);
      expect(fixture.state.nativeSessionId, _sessionB);
      expect(current.boundProfile, 2);
      expect(current.calls, ['bind:2', 'initialize', 'permission', 'start']);
    },
  );

  test('rapid connects share discovery and submit only one start', () async {
    final snapshot = Completer<VpnCoreStatus?>();
    final probe = _Source(snapshot: snapshot.future);
    final current = _Source();
    final fixture = await _fixture([probe, current]);
    final first = fixture.notifier.connect(_profile(2));
    final second = fixture.notifier.connect(_profile(3));
    await _settle();
    expect(current.starts, 0);
    snapshot.complete(
      _native('DISCONNECTED', profileId: null, sessionId: null),
    );
    await Future.wait([first, second]);
    expect(current.starts, 1);
    expect(current.boundProfile, 2);
    expect(probe.stops, 0);
  });

  test('unknown discovery never starts or stops an unowned session', () async {
    final initial = _Source();
    final unknownRetry = _Source();
    final stoppedRetry = _Source(
      snapshot: Future.value(
        _native('DISCONNECTED', profileId: null, sessionId: null),
      ),
    );
    final current = _Source();
    final fixture = await _fixture([
      initial,
      unknownRetry,
      stoppedRetry,
      current,
    ]);
    await fixture.notifier.connect(_profile(2));
    expect(fixture.state.status, ConnectionStatus.error);
    expect(fixture.state.activeServer, isNull);
    expect(initial.disposed, isTrue);
    expect(unknownRetry.disposed, isTrue);
    expect(initial.stops + unknownRetry.stops + current.stops, 0);
    expect(current.starts, 0);
    await fixture.notifier.connect(_profile(2));
    expect(stoppedRetry.calls, ['getStatus']);
    expect(current.starts, 1);
    expect(current.boundProfile, 2);
  });

  test('disconnect cancels a connect awaiting native discovery', () async {
    final snapshot = Completer<VpnCoreStatus?>();
    final probe = _Source(snapshot: snapshot.future);
    final fixture = await _fixture([probe]);
    final connect = fixture.notifier.connect(_profile(2));
    await fixture.notifier.disconnect();
    snapshot.complete(_native('CONNECTED'));
    await connect;
    await _settle();
    expect(fixture.state.status, ConnectionStatus.disconnected);
    expect(probe.disposed, isTrue);
    expect(probe.reattachments, 0);
    expect(probe.stops, 0);
    expect(probe.starts, 0);
  });

  test('disposal cancels a connect awaiting native discovery', () async {
    final snapshot = Completer<VpnCoreStatus?>();
    final probe = _Source(snapshot: snapshot.future);
    final fixture = await _fixture([probe]);
    final connect = fixture.notifier.connect(_profile(2));
    fixture.container.dispose();
    snapshot.complete(_native('CONNECTED'));
    await connect;
    await _settle();
    expect(probe.disposed, isTrue);
    expect(probe.reattachments, 0);
    expect(probe.stops, 0);
    expect(probe.starts, 0);
  });

  test(
    'failed switch preserves the actual native profile and session',
    () async {
      final source = _Source(snapshot: Future.value(_native('CONNECTED')))
        ..stopError = StateError('synthetic stop failure');
      final fixture = await _fixture([source]);
      await fixture.notifier.connect(_profile(2, selected: true));
      expect(fixture.state.status, ConnectionStatus.error);
      expect(fixture.state.activeServer?.id, 1);
      expect(fixture.state.nativeProfileId, 1);
      expect(fixture.state.nativeSessionId, _sessionA);
      expect(fixture.state.usesNativeSessionIdentity, isTrue);
      expect(source.disposed, isFalse);
      expect(source.stops, 1);
      expect(source.starts, 0);
      source.status!(_native('CONNECTED', profileId: 2, sessionId: _sessionB));
      expect(fixture.state.status, ConnectionStatus.error);
      expect(fixture.state.activeServer?.id, 1);
    },
  );

  test(
    'failed stop retains identity while profiles load and successful retry clears it',
    () async {
      final profiles = Completer<List<ServerProfileModel>>();
      final source = _Source(snapshot: Future.value(_native('CONNECTED')))
        ..stopError = StateError('synthetic stop failure');
      final fixture = await _fixture([source], profiles: profiles.future);
      await fixture.notifier.disconnect();
      expect(fixture.state.status, ConnectionStatus.error);
      expect(fixture.state.activeServer, isNull);
      profiles.complete([_profile(1), _profile(2, selected: true)]);
      await _settle();
      expect(fixture.state.status, ConnectionStatus.error);
      expect(fixture.state.activeServer?.id, 1);
      expect(fixture.state.nativeSessionId, _sessionA);
      source.stopError = null;
      await fixture.notifier.disconnect();
      expect(fixture.state.status, ConnectionStatus.disconnected);
      expect(fixture.state.nativeProfileId, isNull);
      expect(fixture.state.nativeSessionId, isNull);
      expect(fixture.state.usesNativeSessionIdentity, isFalse);
      expect(source.stops, 2);
    },
  );
}
