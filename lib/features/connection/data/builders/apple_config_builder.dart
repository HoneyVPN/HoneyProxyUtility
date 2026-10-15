import 'dart:convert';

import '../../../converter/domain/entities/parsed_proxy.dart';
import '../../../settings/data/models/app_settings.dart';
import '../singbox/singbox_config_generator.dart';
import '../singbox/provider_geo_bundle.dart';

/// Apple NetworkExtension policy composed with the shared protocol serializer.
/// Libbox's PlatformInterface.OpenTun supplies the actual utun descriptor; this
/// builder neither opens an interface nor launches a standalone core process.
class AppleConfigBuilder {
  const AppleConfigBuilder({this.geoPaths, this.providerRouting});

  final Map<String, String>? geoPaths;
  final ProviderGeoBundle? providerRouting;

  String generate(ParsedProxy proxy, AppSettings settings) {
    if (settings.connectionMode != ConnectionMode.tunnel) {
      throw UnsupportedError(
        'System proxy mode is unavailable on Apple platforms',
      );
    }
    final effectiveSettings = settings.copyWith(allowLanConnections: false);
    final config =
        jsonDecode(
              SingboxConfigGenerator(
                geoPaths: geoPaths,
                providerRouting: providerRouting,
                target: SingboxConfigTarget.apple,
              ).generateForAndroid(proxy, effectiveSettings),
            )
            as Map<String, dynamic>;
    final localProxyInbounds = (config['inbounds'] as List)
        .cast<Map<String, dynamic>>();
    config['inbounds'] = [
      {
        'type': 'tun',
        'tag': 'tun-in',
        // A /30 supplies the additional address used by libbox DNS hijacking.
        // Capture both IP families even when DNS prefers IPv4.
        'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        'mtu': 1500,
        'auto_route': true,
        'stack': 'gvisor',
      },
      ...localProxyInbounds,
    ];
    final route = config['route'] as Map<String, dynamic>;
    route['rules'] = (route['rules'] as List)
        .cast<Map<String, dynamic>>()
        .where((rule) => !_isAndroidWorkaround(rule))
        .toList();
    // Native libbox must implement the default-interface monitor to keep the
    // encrypted peer traffic on the physical interface instead of the utun.
    route['auto_detect_interface'] = true;
    // The extension uses libbox's command/status API, without a fixed TCP 9090
    // listener that could collide with another installed client.
    config.remove('experimental');
    return jsonEncode(config);
  }

  static bool _isAndroidWorkaround(Map<String, dynamic> rule) {
    final cidrs = rule['ip_cidr'];
    final ports = rule['port'];
    final privateDnsProbe =
        rule['action'] == 'reject' &&
        cidrs is List &&
        cidrs.contains('172.19.0.2/32') &&
        ports is List &&
        ports.contains(853);
    final ruIpv6Fallback =
        rule['rule_set'] == 'ru' &&
        rule['ip_version'] == 6 &&
        rule['outbound'] == 'proxy';
    return privateDnsProbe || ruIpv6Fallback;
  }
}
