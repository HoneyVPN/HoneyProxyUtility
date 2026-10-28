import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/vpn_disclosure_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'fresh installation requires disclosure without recording consent',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(await container.read(vpnDisclosureProvider.future), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('vpn_disclosure_accepted_v2'), isFalse);
    },
  );

  test(
    'acceptance of the old disclosure does not bypass the corrected one',
    () async {
      SharedPreferences.setMockInitialValues({'vpn_disclosure_accepted': true});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(await container.read(vpnDisclosureProvider.future), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('vpn_disclosure_accepted'), isTrue);
      expect(prefs.containsKey('vpn_disclosure_accepted_v2'), isFalse);
    },
  );

  test(
    'explicit acceptance persists across provider container rebuilds',
    () async {
      SharedPreferences.setMockInitialValues({'vpn_disclosure_accepted': true});
      final original = ProviderContainer();
      try {
        expect(await original.read(vpnDisclosureProvider.future), isFalse);
        await original.read(vpnDisclosureProvider.notifier).accept();
        expect(original.read(vpnDisclosureProvider).requireValue, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('vpn_disclosure_accepted_v2'), isTrue);
      } finally {
        original.dispose();
      }

      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      expect(await restarted.read(vpnDisclosureProvider.future), isTrue);
    },
  );
}
