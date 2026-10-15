/// Provider declarations only. Importing these values never changes app settings.
enum ProviderRoutingOperation { add, onadd, off }

enum ProviderRuleKind {
  fullDomain,
  domainSuffix,
  keyword,
  regularExpression,
  dotless,
  geoSite,
  ipAddress,
  ipNetwork,
  geoIp,
}

class ProviderRoutingRule {
  const ProviderRoutingRule({
    required this.source,
    required this.kind,
    required this.value,
    this.negated = false,
    this.attribute,
  });

  /// Original validated spelling; no inferred core configuration is emitted.
  final String source;
  final ProviderRuleKind kind;
  final String value;
  final bool negated;

  /// Literal @-joined Xray attribute keys. A ! prefix is part of a key;
  /// it does not mean complement. Multiple keys require all to be present.
  final String? attribute;
}

class ProviderRoutingDeclarations {
  ProviderRoutingDeclarations({
    this.globalProxy,
    this.fakeDns,
    this.domainStrategy,
    this.routeOrder,
    this.preferChunkFiles,
    Map<String, String> dns = const {},
    Map<String, String> dnsHosts = const {},
  }) : dns = Map.unmodifiable(dns),
       dnsHosts = Map.unmodifiable(dnsHosts);

  final bool? globalProxy;
  final bool? fakeDns;
  final String? domainStrategy;
  final String? routeOrder;

  /// Recorded optimization request. Runtime downloads verified whole DAT
  /// assets; this declaration never enables executable or local-file input.
  final bool? preferChunkFiles;
  final Map<String, String> dns;
  final Map<String, String> dnsHosts;
}

class ProviderRoutingProfile {
  ProviderRoutingProfile({
    this.name,
    this.geoIpUrl,
    this.geoSiteUrl,
    this.lastUpdatedUnix,
    required this.declarations,
    List<ProviderRoutingRule> directSites = const [],
    List<ProviderRoutingRule> proxySites = const [],
    List<ProviderRoutingRule> blockSites = const [],
    List<ProviderRoutingRule> directIp = const [],
    List<ProviderRoutingRule> proxyIp = const [],
    List<ProviderRoutingRule> blockIp = const [],
  }) : directSites = List.unmodifiable(directSites),
       proxySites = List.unmodifiable(proxySites),
       blockSites = List.unmodifiable(blockSites),
       directIp = List.unmodifiable(directIp),
       proxyIp = List.unmodifiable(proxyIp),
       blockIp = List.unmodifiable(blockIp);

  final String? name;

  /// Validated HTTPS references, not downloaded or verified geo assets.
  final String? geoIpUrl;
  final String? geoSiteUrl;
  final int? lastUpdatedUnix;
  final ProviderRoutingDeclarations declarations;
  final List<ProviderRoutingRule> directSites, proxySites, blockSites;
  final List<ProviderRoutingRule> directIp, proxyIp, blockIp;

  Map<String, Object?> toJson() => {
    if (name != null) 'Name': name,
    if (geoIpUrl != null) 'Geoipurl': geoIpUrl,
    if (geoSiteUrl != null) 'Geositeurl': geoSiteUrl,
    if (lastUpdatedUnix != null) 'LastUpdated': lastUpdatedUnix,
    if (declarations.globalProxy != null)
      'GlobalProxy': declarations.globalProxy,
    if (declarations.fakeDns != null) 'FakeDNS': declarations.fakeDns,
    if (declarations.domainStrategy != null)
      'DomainStrategy': declarations.domainStrategy,
    if (declarations.routeOrder != null) 'RouteOrder': declarations.routeOrder,
    if (declarations.preferChunkFiles != null)
      'UseChunkFiles': declarations.preferChunkFiles,
    ...declarations.dns,
    if (declarations.dnsHosts.isNotEmpty) 'DnsHosts': declarations.dnsHosts,
    'DirectSites': directSites.map((r) => r.source).toList(),
    'ProxySites': proxySites.map((r) => r.source).toList(),
    'BlockSites': blockSites.map((r) => r.source).toList(),
    'DirectIp': directIp.map((r) => r.source).toList(),
    'ProxyIp': proxyIp.map((r) => r.source).toList(),
    'BlockIp': blockIp.map((r) => r.source).toList(),
  };
}

class ProviderRoutingCommand {
  const ProviderRoutingCommand({required this.operation, this.profile});
  final ProviderRoutingOperation operation;
  final ProviderRoutingProfile? profile;

  Map<String, Object?> toJson() => {
    'operation': operation.name,
    if (profile != null) 'profile': profile!.toJson(),
  };
}

/// Metadata is scoped to one subscription, never to global app preferences.
/// Declarations are persisted with the subscription; only verified compiled
/// geo predicates enter a later connection's immutable configuration.
class ProviderRoutingMetadata {
  ProviderRoutingMetadata({
    required this.subscriptionId,
    required List<ProviderRoutingCommand> commands,
  }) : commands = List.unmodifiable(commands);

  final int subscriptionId;
  final List<ProviderRoutingCommand> commands;

  Map<String, Object?> toJson() => {
    'schema': 1,
    'subscriptionId': subscriptionId,
    'commands': commands.map((c) => c.toJson()).toList(),
  };
}

class ProviderRoutingEnvelope {
  const ProviderRoutingEnvelope({
    required this.metadata,
    required this.proxyBody,
    required this.base64BodyDecoded,
  });
  final ProviderRoutingMetadata metadata;

  /// The body with standalone routing directives removed. It still requires
  /// the existing proxy parser; no proxy credentials are interpreted here.
  final String proxyBody;
  final bool base64BodyDecoded;
}
