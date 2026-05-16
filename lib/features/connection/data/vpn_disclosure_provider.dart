import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kDisclosureAccepted = 'vpn_disclosure_accepted';

final vpnDisclosureProvider =
    AsyncNotifierProvider<VpnDisclosureNotifier, bool>(VpnDisclosureNotifier.new);

class VpnDisclosureNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kDisclosureAccepted) ?? false;
  }

  Future<void> accept() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDisclosureAccepted, true);
    state = const AsyncData(true);
  }
}
