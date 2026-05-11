import 'dart:convert';
import 'package:flutter/material.dart';

enum RoutingMode {
  global,    // All traffic through proxy
  bypassRU,  // Russia direct, rest through proxy
  rules,     // Custom rules
}

enum ConnectionMode {
  tunnel,  // TUN — system-wide VPN, all apps automatically
  proxy,   // SOCKS5/HTTP proxy on localhost:2080
}

enum DnsPreset {
  cloudflare, // 1.1.1.1 / DoH: https://cloudflare-dns.com/dns-query
  google,     // 8.8.8.8 / DoH: https://dns.google/dns-query
  adguard,    // DoH: https://dns.adguard-dns.com/dns-query
  custom,
}

enum IpType { ipv4, ipv6, both }

enum TunStack { system, gvisor, mixed }

enum LogLevel { trace, debug, info, warn, error }

class AppSettings {
  final ThemeMode themeMode;
  final RoutingMode routingMode;
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
  final bool blockAds;
  final bool enableFakeip;
  final LogLevel logLevel;
  final int socksPort;
  final int httpPort;

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.routingMode = RoutingMode.bypassRU,
    this.connectionMode = ConnectionMode.tunnel,
    this.dnsPreset = DnsPreset.cloudflare,
    this.customDnsUrl = '',
    this.fragmentationEnabled = false,
    this.multiplexerEnabled = false,
    this.preferredIpType = IpType.both,
    this.allowLanConnections = false,
    this.locale = 'en',
    this.tunStack = TunStack.mixed,
    this.blockAds = true,
    this.enableFakeip = true,
    this.logLevel = LogLevel.warn,
    this.socksPort = 2080,
    this.httpPort = 2081,
  });

  AppSettings copyWith({
    ThemeMode? themeMode,
    RoutingMode? routingMode,
    ConnectionMode? connectionMode,
    DnsPreset? dnsPreset,
    String? customDnsUrl,
    bool? fragmentationEnabled,
    bool? multiplexerEnabled,
    IpType? preferredIpType,
    bool? allowLanConnections,
    String? locale,
    TunStack? tunStack,
    bool? blockAds,
    bool? enableFakeip,
    LogLevel? logLevel,
    int? socksPort,
    int? httpPort,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    routingMode: routingMode ?? this.routingMode,
    connectionMode: connectionMode ?? this.connectionMode,
    dnsPreset: dnsPreset ?? this.dnsPreset,
    customDnsUrl: customDnsUrl ?? this.customDnsUrl,
    fragmentationEnabled: fragmentationEnabled ?? this.fragmentationEnabled,
    multiplexerEnabled: multiplexerEnabled ?? this.multiplexerEnabled,
    preferredIpType: preferredIpType ?? this.preferredIpType,
    allowLanConnections: allowLanConnections ?? this.allowLanConnections,
    locale: locale ?? this.locale,
    tunStack: tunStack ?? this.tunStack,
    blockAds: blockAds ?? this.blockAds,
    enableFakeip: enableFakeip ?? this.enableFakeip,
    logLevel: logLevel ?? this.logLevel,
    socksPort: socksPort ?? this.socksPort,
    httpPort: httpPort ?? this.httpPort,
  );

  Map<String, dynamic> toJson() => {
    'themeMode': themeMode.index,
    'routingMode': routingMode.index,
    'connectionMode': connectionMode.index,
    'dnsPreset': dnsPreset.index,
    'customDnsUrl': customDnsUrl,
    'fragmentationEnabled': fragmentationEnabled,
    'multiplexerEnabled': multiplexerEnabled,
    'preferredIpType': preferredIpType.index,
    'allowLanConnections': allowLanConnections,
    'locale': locale,
    'tunStack': tunStack.index,
    'blockAds': blockAds,
    'enableFakeip': enableFakeip,
    'logLevel': logLevel.index,
    'socksPort': socksPort,
    'httpPort': httpPort,
  };

  factory AppSettings.fromJson(Map<String, dynamic> m) => AppSettings(
    themeMode: ThemeMode.values[m['themeMode'] as int? ?? 0],
    routingMode: RoutingMode.values[m['routingMode'] as int? ?? 1],
    connectionMode: ConnectionMode.values[m['connectionMode'] as int? ?? 0],
    dnsPreset: DnsPreset.values[m['dnsPreset'] as int? ?? 0],
    customDnsUrl: m['customDnsUrl'] as String? ?? '',
    fragmentationEnabled: m['fragmentationEnabled'] as bool? ?? false,
    multiplexerEnabled: m['multiplexerEnabled'] as bool? ?? false,
    preferredIpType: IpType.values[m['preferredIpType'] as int? ?? 2],
    allowLanConnections: m['allowLanConnections'] as bool? ?? false,
    locale: m['locale'] as String? ?? 'en',
    tunStack: TunStack.values[m['tunStack'] as int? ?? 2],
    blockAds: m['blockAds'] as bool? ?? true,
    enableFakeip: m['enableFakeip'] as bool? ?? true,
    logLevel: LogLevel.values[m['logLevel'] as int? ?? 3],
    socksPort: m['socksPort'] as int? ?? 2080,
    httpPort: m['httpPort'] as int? ?? 2081,
  );

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
    RoutingMode.global   => 'Global',
    RoutingMode.bypassRU => 'Bypass Russia',
    RoutingMode.rules    => 'Rule-based',
  };

  String get description => switch (this) {
    RoutingMode.global   => 'All traffic through proxy',
    RoutingMode.bypassRU => 'RU & .ru domains go direct, rest via proxy',
    RoutingMode.rules    => 'Custom per-domain/IP rules',
  };
}

extension ConnectionModeExt on ConnectionMode {
  String get label => switch (this) {
    ConnectionMode.tunnel => 'VPN Tunnel',
    ConnectionMode.proxy  => 'System Proxy',
  };

  String get description => switch (this) {
    ConnectionMode.tunnel => 'TUN interface — all apps, no config needed',
    ConnectionMode.proxy  => '',
  };

  IconData get icon => switch (this) {
    ConnectionMode.tunnel => Icons.vpn_lock_outlined,
    ConnectionMode.proxy  => Icons.device_hub_outlined,
  };
}

extension DnsPresetExt on DnsPreset {
  String get label => switch (this) {
    DnsPreset.cloudflare => 'Cloudflare',
    DnsPreset.google     => 'Google',
    DnsPreset.adguard    => 'AdGuard',
    DnsPreset.custom     => 'Custom',
  };

  String get serverUrl => switch (this) {
    DnsPreset.cloudflare => 'https://cloudflare-dns.com/dns-query',
    DnsPreset.google     => 'https://dns.google/dns-query',
    DnsPreset.adguard    => 'https://dns.adguard-dns.com/dns-query',
    DnsPreset.custom     => '',
  };

  String get ip => switch (this) {
    DnsPreset.cloudflare => '1.1.1.1',
    DnsPreset.google     => '8.8.8.8',
    DnsPreset.adguard    => '94.140.14.14',
    DnsPreset.custom     => '—',
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
    TunStack.mixed  => 'Mixed',
  };
}

extension LogLevelExt on LogLevel {
  String get label => switch (this) {
    LogLevel.trace => 'Trace',
    LogLevel.debug => 'Debug',
    LogLevel.info  => 'Info',
    LogLevel.warn  => 'Warn',
    LogLevel.error => 'Error',
  };
}
