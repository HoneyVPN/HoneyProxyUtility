import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/datasources/singbox_datasource.dart';
import 'package:honeyproxyutility/features/connection/domain/entities/vpn_core_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android stream failure cannot confirm that native VPN stopped',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const methods = MethodChannel('ru.honeyvpn.proxy/vpn');
      const stream = EventChannel('ru.honeyvpn.proxy/vpn_stats');
      final statuses = <VpnCoreStatus>[];
      final errors = <String>[];
      final nativeStop = Completer<void>();
      var nativeRunning = true;
      final stopRequested = Completer<void>();
      var stopReplied = false;
      late MockStreamHandlerEventSink events;
      messenger.setMockStreamHandler(
        stream,
        MockStreamHandler.inline(
          onListen: (_, sink) {
            events = sink;
          },
        ),
      );
      messenger.setMockMethodCallHandler(methods, (call) async {
        switch (call.method) {
          case 'checkStatus':
            return nativeRunning;
          case 'getStatus':
            return {'state': nativeRunning ? 'CONNECTED' : 'DISCONNECTED'};
          case 'stop':
            stopRequested.complete();
            await nativeStop.future;
            nativeRunning = false;
            return null;
        }
        return null;
      });
      final source = VpnDatasource(
        platform: VpnPlatform.android,
        onStatusChanged: statuses.add,
        onError: errors.add,
      );
      addTearDown(source.dispose);
      source.reattach();
      await Future<void>.delayed(Duration.zero);
      events.success({'event': 'started'});
      await Future<void>.delayed(Duration.zero);
      events.error(
        code: 'CHANNEL_TRANSPORT_FAILED',
        message: 'Synthetic fault',
      );
      await Future<void>.delayed(Duration.zero);
      expect(errors, [VpnDatasource.nativeStatusUnavailableMessage]);
      expect(statuses.map((s) => s.state), ['CONNECTED']);
      expect(await source.checkRunning(), isTrue);
      expect((await source.readCurrentStatus())?.state, 'CONNECTED');
      final stopping = source.stop().then((_) => stopReplied = true);
      await stopRequested.future.timeout(const Duration(seconds: 2));
      expect(stopReplied, isFalse);
      expect(await source.checkRunning(), isTrue);
      expect(statuses.any((s) => s.state == 'DISCONNECTED'), isFalse);
      nativeStop.complete();
      await stopping;
      expect(stopReplied, isTrue);
      expect(await source.checkRunning(), isFalse);
      expect((await source.readCurrentStatus())?.state, 'DISCONNECTED');
    },
  );
}
