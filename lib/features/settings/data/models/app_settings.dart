import 'dart:convert';
import 'package:flutter/material.dart';

enum RoutingMode {
  global, // All traffic through proxy
  bypassRU, // Russia direct, rest through proxy
  rules, // Custom rules
}

enum GeoRoutingMode { builtIn, provider, combined }

enum ConnectionMode {
  tunnel, // TUN — system-wide VPN, all apps automatically
  proxy, // SOCKS5/HTTP proxy on localhost:2080
}

enum DnsPreset {
  cloudflare, // 1.1.1.1 / DoH: https://cloudflare-dns.com/dns-query
  google, // 8.8.8.8 / DoH: https://dns.google/dns-query
  adguard, // DoH: https://dns.adguard-dns.com/dns-query
  custom,
}

enum IpType { ipv4, ipv6, both }

enum TunStack { system, gvisor, mixed }

enum LogLevel { trace, debug, info, warn, error }

enum SettingsValidationIssue {
  ports,
  dnsAddress,
  dnsPort,
  dnsExtras,
  dnsTlsPath,
}

/// A safe code for UI localization; never includes a credential-bearing URL.
class SettingsValidationException extends ArgumentError {
  SettingsValidationException(this.issue)
    : super('settingsValidation:${issue.name}');
  final SettingsValidationIssue issue;
  String get code => 'settingsValidation:${issue.name}';
  @override
  String toString() => code;
}

class AppSettings {
  final ThemeMode themeMode;
  final RoutingMode routingMode;
  final GeoRoutingMode geoRoutingMode;
  final ConnectionMode connectionMode;
  final DnsPreset dnsPreset;
  final String customDnsUrl;
  final bool fragmentationEnabled;
  final bool multiplexerEnabled;
  final IpType preferredIpType;
  final bool allowLanConnections;
  final String locale;
  // sing-box / VPN engine settings
  final TunStack tunStack;
  final bool enableFakeip;
  final LogLevel logLevel;
  final int socksPort;
  final int httpPort;

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.routingMode = RoutingMode.bypassRU,
    this.geoRoutingMode = GeoRoutingMode.builtIn,
    this.connectionMode = ConnectionMode.tunnel,
    this.dnsPreset = DnsPreset.cloudflare,
    this.customDnsUrl = '',
    this.fragmentationEnabled = false,
    this.multiplexerEnabled = false,
    this.preferredIpType = IpType.both,
    this.allowLanConnections = false,
    this.locale = 'en',
    this.tunStack = TunStack.mixed,
    this.enableFakeip = true,
    this.logLevel = LogLevel.warn,
    this.socksPort = 2080,
    this.httpPort = 2081,
  });

  AppSettings copyWith({
    ThemeMode? themeMode,
    RoutingMode? routingMode,
    GeoRoutingMode? geoRoutingMode,
    ConnectionMode? connectionMode,
    DnsPreset? dnsPreset,
    String? customDnsUrl,
    bool? fragmentationEnabled,
    bool? multiplexerEnabled,
    IpType? preferredIpType,
    bool? allowLanConnections,
    String? locale,
    TunStack? tunStack,
    bool? enableFakeip,
    LogLevel? logLevel,
    int? socksPort,
    int? httpPort,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    routingMode: routingMode ?? this.routingMode,
    geoRoutingMode: geoRoutingMode ?? this.geoRoutingMode,
    connectionMode: connectionMode ?? this.connectionMode,
    dnsPreset: dnsPreset ?? this.dnsPreset,
    customDnsUrl: customDnsUrl ?? this.customDnsUrl,
    fragmentationEnabled: fragmentationEnabled ?? this.fragmentationEnabled,
    multiplexerEnabled: multiplexerEnabled ?? this.multiplexerEnabled,
    preferredIpType: preferredIpType ?? this.preferredIpType,
    allowLanConnections: allowLanConnections ?? this.allowLanConnections,
    locale: locale ?? this.locale,
    tunStack: tunStack ?? this.tunStack,
    enableFakeip: enableFakeip ?? this.enableFakeip,
    logLevel: logLevel ?? this.logLevel,
    socksPort: socksPort ?? this.socksPort,
    httpPort: httpPort ?? this.httpPort,
  );

  // Serialize enums by name (string) so adding new enum values never corrupts saved settings.
  Map<String, dynamic> toJson() => {
    'themeMode': themeMode.index, // ThemeMode is from Flutter SDK, keep index
    'routingMode': routingMode.name,
    'geoRoutingMode': geoRoutingMode.name,
    'connectionMode': connectionMode.name,
    'dnsPreset': dnsPreset.name,
    'customDnsUrl': customDnsUrl,
    'fragmentationEnabled': fragmentationEnabled,
    'multiplexerEnabled': multiplexerEnabled,
    'preferredIpType': preferredIpType.name,
    'allowLanConnections': allowLanConnections,
    'locale': locale,
    'tunStack': tunStack.name,
    'enableFakeip': enableFakeip,
    'logLevel': logLevel.name,
    'socksPort': socksPort,
    'httpPort': httpPort,
  };

  factory AppSettings.fromJson(Map<String, dynamic> m) {
    final socks = _storedPort(m['socksPort'], 2080);
    final http = _storedPort(m['httpPort'], 2081);
    final storedRouting = _parseEnum(
      RoutingMode.values,
      m['routingMode'],
      RoutingMode.bypassRU,
    );
    return AppSettings(
      themeMode: _parseEnum(ThemeMode.values, m['themeMode'], ThemeMode.system),
      // The removed third picker option had exactly the bypassRU policy.
      routingMode: storedRouting == RoutingMode.rules
          ? RoutingMode.bypassRU
          : storedRouting,
      geoRoutingMode: _parseEnum(GeoRoutingMode.values, m['geoRoutingMode'],
        GeoRoutingMode.builtIn),
      connectionMode: _parseEnum(
        ConnectionMode.values,
        m['connectionMode'],
        ConnectionMode.tunnel,
      ),
      dnsPreset: _parseEnum(
        DnsPreset.values,
        m['dnsPreset'],
        DnsPreset.cloudflare,
      ),
      customDnsUrl: m['customDnsUrl'] is String
          ? m['customDnsUrl'] as String
          : '',
      fragmentationEnabled: m['fragmentationEnabled'] == true,
      multiplexerEnabled: m['multiplexerEnabled'] == true,
      preferredIpType: _parseEnum(
        IpType.values,
        m['preferredIpType'],
        IpType.both,
      ),
      allowLanConnections: m['allowLanConnections'] == true,
      locale: m['locale'] == 'ru' ? 'ru' : 'en',
      tunStack: _parseEnum(TunStack.values, m['tunStack'], TunStack.mixed),
      enableFakeip: m['enableFakeip'] is bool
          ? m['enableFakeip'] as bool
          : true,
      logLevel: _parseEnum(LogLevel.values, m['logLevel'], LogLevel.warn),
      socksPort: socks == http ? 2080 : socks,
      httpPort: socks == http ? 2081 : http,
    );
  }

  static int _storedPort(dynamic raw, int fallback) =>
      raw is int && raw >= 1 && raw <= 65535 && raw != 9090 ? raw : fallback;

  static void validatePorts(int socks, int http) {
    if (socks < 1 ||
        socks > 65535 ||
        http < 1 ||
        http > 65535 ||
        socks == http ||
        socks == 9090 ||
        http == 9090) {
      throw SettingsValidationException(SettingsValidationIssue.ports);
    }
  }

  static SettingsValidationIssue? customDnsIssue(String address) {
    try {
      final uri = Uri.tryParse(address.trim());
      if (uri == null ||
          uri.host.isEmpty ||
          (uri.scheme != 'https' && uri.scheme != 'tls')) {
        return SettingsValidationIssue.dnsAddress;
      }
      if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
        return SettingsValidationIssue.dnsPort;
      }
      if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
        return SettingsValidationIssue.dnsExtras;
      }
      if (uri.scheme == 'tls' && uri.path.isNotEmpty && uri.path != '/') {
        return SettingsValidationIssue.dnsTlsPath;
      }
      return null;
    } on FormatException {
      return SettingsValidationIssue.dnsAddress;
    }
  }

  void validateNetworkSettings({bool validateProxyPorts = true}) {
    if (validateProxyPorts) validatePorts(socksPort, httpPort);
    if (dnsPreset == DnsPreset.custom) {
      final issue = customDnsIssue(customDnsUrl);
      if (issue != null) throw SettingsValidationException(issue);
    }
  }

  // Handles both legacy integer indices and new string names for backward compatibility.
  static T _parseEnum<T extends Enum>(List<T> values, dynamic raw, T fallback) {
    if (raw is String) {
      return values.firstWhere((e) => e.name == raw, orElse: () => fallback);
    }
    if (raw is int && raw >= 0 && raw < values.length) {
      return values[raw];
    }
    return fallback;
  }

  static AppSettings fromJsonString(String s) {
    try {
      return AppSettings.fromJson(json.decode(s) as Map<String, dynamic>);
    } catch (_) {
      return const AppSettings();
    }
  }

  String toJsonString() => json.encode(toJson());
}

extension RoutingModeExt on RoutingMode {
  String get label => switch (this) {
    RoutingMode.global => 'Global',
    RoutingMode.bypassRU => 'Bypass Russia',
    RoutingMode.rules => 'Rule-based',
  };

  String get description => switch (this) {
    RoutingMode.global => 'All traffic through proxy',
    RoutingMode.bypassRU => 'RU & .ru domains go direct, rest via proxy',
    RoutingMode.rules => 'Legacy alias of the built-in Russia bypass policy',
  };
}

extension ConnectionModeExt on ConnectionMode {
  String get label => switch (this) {
    ConnectionMode.tunnel => 'VPN Tunnel',
    ConnectionMode.proxy => 'System Proxy',
  };

  String get description => switch (this) {
    ConnectionMode.tunnel => 'TUN interface — all apps, no config needed',
    ConnectionMode.proxy => 'SOCKS5/HTTP proxy on localhost:2080',
  };

  IconData get icon => switch (this) {
    ConnectionMode.tunnel => Icons.vpn_lock_outlined,
    ConnectionMode.proxy => Icons.device_hub_outlined,
  };
}

extension DnsPresetExt on DnsPreset {
  String get label => switch (this) {
    DnsPreset.cloudflare => 'Cloudflare',
    DnsPreset.google => 'Google',
    DnsPreset.adguard => 'AdGuard',
    DnsPreset.custom => 'Custom',
  };

  String get serverUrl => switch (this) {
    DnsPreset.cloudflare => 'https://cloudflare-dns.com/dns-query',
    DnsPreset.google => 'https://dns.google/dns-query',
    DnsPreset.adguard => 'https://dns.adguard-dns.com/dns-query',
    DnsPreset.custom => '',
  };

  String get ip => switch (this) {
    DnsPreset.cloudflare => '1.1.1.1',
    DnsPreset.google => '8.8.8.8',
    DnsPreset.adguard => '94.140.14.14',
    DnsPreset.custom => '—',
  };
}

extension IpTypeExt on IpType {
  String get label => switch (this) {
    IpType.ipv4 => 'IPv4',
    IpType.ipv6 => 'IPv6',
    IpType.both => 'IPv4 + IPv6',
  };
}

extension TunStackExt on TunStack {
  String get label => switch (this) {
    TunStack.system => 'System',
    TunStack.gvisor => 'gVisor',
    TunStack.mixed => 'Mixed',
  };
}

extension LogLevelExt on LogLevel {
  String get label => switch (this) {
    LogLevel.trace => 'Trace',
    LogLevel.debug => 'Debug',
    LogLevel.info => 'Info',
    LogLevel.warn => 'Warn',
    LogLevel.error => 'Error',
  };
}
