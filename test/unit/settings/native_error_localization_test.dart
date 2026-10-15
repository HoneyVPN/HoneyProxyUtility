import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/app/l10n/strings.dart';

void main() {
  for (final locale in ['ru', 'en']) {
    final strings = S(locale);
    test('$locale native stop uncertainty is preserved in the UI', () {
      for (final reason in [
        'VPN stop could not be confirmed',
        'VPN stop was superseded by a newer command',
        'Cannot stop the Android VPN service',
      ]) {
        expect(strings.nativeVpnError(reason), strings.vpnStopFailed);
      }
      expect(
        strings.nativeVpnError('sing-box ownership could not be confirmed'),
        strings.vpnStatusUnavailable,
      );
    });
    test(
      '$locale bounded process failures distinguish startup and lost connection',
      () {
        for (final role in ['sing-box', 'VPN forwarder']) {
          for (final metadata in [
            'exit=0',
            'exit=255',
            'signal=1',
            'signal=128',
          ]) {
            expect(
              strings.nativeVpnError(
                '$role stopped during startup ($metadata)',
              ),
              strings.vpnStartFailed,
            );
            expect(
              strings.nativeVpnError('$role stopped unexpectedly ($metadata)'),
              strings.vpnConnectionEnded,
            );
          }
        }
      },
    );
    test(
      '$locale unknown and malformed native diagnostics never expose data',
      () {
        for (final reason in [
          'https://user:password@private.example/token',
          'Could not create /home/private-user/config-with-secret.json',
          'VPN configuration is missing token=secret',
          'sing-box stopped unexpectedly (exit=256)',
          'sing-box stopped unexpectedly (exit=-1)',
          'sing-box stopped unexpectedly (signal=0)',
          'sing-box stopped unexpectedly (signal=129)',
          'sing-box stopped unexpectedly (exit=1)\nhttps://private.example/token',
          'foreign-role stopped unexpectedly (exit=1)',
          'x' * 100000,
        ]) {
          final visible = strings.nativeVpnError(reason);
          expect(visible, strings.vpnUnknownFailure);
          expect(visible, isNot(contains('private')));
          expect(visible, isNot(contains('secret')));
          expect(visible, isNot(contains('https://')));
        }
      },
    );
  }
}
