import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../../settings/data/models/app_settings.dart';
import '../../../subscriptions/domain/entities/provider_geo_state.dart';
import '../../../subscriptions/domain/entities/provider_routing_metadata.dart';
import 'provider_geo_dat_decoder.dart';
import 'provider_geo_regex_validator.dart';

String providerGeoHash(List<int> bytes) => sha256.convert(bytes).toString();
String providerGeoScope(int id, String url) =>
    providerGeoHash(utf8.encode(jsonEncode([id, url])));
String providerMetadataDigest(ProviderRoutingMetadata metadata) =>
    providerGeoHash(utf8.encode(jsonEncode(metadata.toJson())));

/// Complete immutable rules. Sessions consume memory snapshots, never mutable
/// local files, provider URLs or a global currently-selected-provider pointer.
class ProviderGeoBundle {
  ProviderGeoBundle._(this.scope, this.metadataDigest, this.groups);
  static const maximumInlineBytes = 640 * 1024;
  static const maximumStrings = 30000;
  final String scope, metadataDigest;
  final Map<String, List<Map<String, dynamic>>> groups;

  String get digest => providerGeoHash(utf8.encode(jsonEncode(toJson())));
  String tag(String role) =>
      'pgeo-' +
      scope.substring(0, 16) +
      '-' +
      digest.substring(0, 16) +
      '-' +
      role;
  Map<String, dynamic> toJson() => {
    'schema': 1,
    'scope': scope,
    'metadataDigest': metadataDigest,
    'groups': groups,
  };
  List<Map<String, dynamic>> get ruleSets => [
    for (final role in ['block', 'proxy', 'direct'])
      if (groups[role]!.isNotEmpty)
        {'type': 'inline', 'tag': tag(role), 'rules': groups[role]},
  ];
  List<Map<String, dynamic>> rulesFor(String role) => groups[role]!.isEmpty
      ? []
      : [
          {
            'rule_set': tag(role),
            if (role == 'block') 'action': 'reject' else 'outbound': role,
          },
        ];

  factory ProviderGeoBundle.fromJson(Map<String, dynamic> json) {
    final hash = RegExp(r'^[0-9a-f]{64}$');
    if (json['schema'] != 1 ||
        json.keys.any(
          (key) =>
              !{'schema', 'scope', 'metadataDigest', 'groups'}.contains(key),
        ) ||
        json['scope'] is! String ||
        !hash.hasMatch(json['scope'] as String) ||
        json['metadataDigest'] is! String ||
        !hash.hasMatch(json['metadataDigest'] as String) ||
        json['groups'] is! Map) {
      throw const ProviderGeoException(ProviderGeoIssue.invalid);
    }
    final raw = json['groups'] as Map;
    if (raw.length != 3 ||
        !['block', 'proxy', 'direct'].every(raw.containsKey)) {
      throw const ProviderGeoException(ProviderGeoIssue.invalid);
    }
    var strings = 0;
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final role in ['block', 'proxy', 'direct']) {
      final rows = raw[role];
      if (rows is! List || rows.length > 64) {
        throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
      }
      final validated = <Map<String, dynamic>>[];
      for (final row in rows) {
        if (row is! Map<String, dynamic>) {
          throw const ProviderGeoException(ProviderGeoIssue.invalid);
        }
        if (row.isEmpty ||
            row.keys.any(
              (key) => !{
                'domain',
                'domain_suffix',
                'domain_keyword',
                'domain_regex',
                'ip_cidr',
                'invert',
              }.contains(key),
            ) ||
            row.keys.every((key) => key == 'invert')) {
          throw const ProviderGeoException(ProviderGeoIssue.invalid);
        }
        if (row.containsKey('invert') && row['invert'] is! bool) {
          throw const ProviderGeoException(ProviderGeoIssue.invalid);
        }
        // Domain classes are a union. IP must be its own atom, never an
        // accidental domain AND IP constraint or an inverted mixed predicate.
        if (row.containsKey('ip_cidr') &&
            row.keys.any((key) => key != 'ip_cidr' && key != 'invert')) {
          throw const ProviderGeoException(ProviderGeoIssue.invalid);
        }
        final copy = <String, dynamic>{};
        for (final entry in row.entries) {
          if (entry.key == 'invert') {
            copy[entry.key] = entry.value;
            continue;
          }
          final values = entry.value;
          if (values is! List || values.isEmpty) {
            throw const ProviderGeoException(ProviderGeoIssue.invalid);
          }
          final safe = <String>[];
          for (final value in values) {
            if (value is! String ||
                value.isEmpty ||
                RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
              throw const ProviderGeoException(ProviderGeoIssue.invalid);
            }
            if (++strings > maximumStrings) {
              throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
            }
            switch (entry.key) {
              case 'domain' || 'domain_suffix':
                final domain = value.startsWith('.')
                    ? value.substring(1)
                    : value;
                if ((entry.key == 'domain' && value.startsWith('.')) ||
                    value.length > 253 ||
                    !domain
                        .split('.')
                        .every(
                          (label) =>
                              label.length <= 63 &&
                              RegExp(
                                r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$',
                              ).hasMatch(label),
                        )) {
                  throw const ProviderGeoException(ProviderGeoIssue.invalid);
                }
              case 'domain_regex':
                validateProviderRegex(value);
              case 'domain_keyword':
                if (value.length > 512) {
                  throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
                }
              case 'ip_cidr':
                if (canonicalProviderCidr(value) != value) {
                  throw const ProviderGeoException(ProviderGeoIssue.invalid);
                }
            }
            safe.add(value);
          }
          copy[entry.key] = List<String>.unmodifiable(safe);
        }
        validated.add(Map<String, dynamic>.unmodifiable(copy));
      }
      groups[role] = List<Map<String, dynamic>>.unmodifiable(validated);
    }
    final bundle = ProviderGeoBundle._(
      json['scope'] as String,
      json['metadataDigest'] as String,
      Map.unmodifiable(groups),
    );
    if (utf8
            .encode(
              jsonEncode({
                'rule_set': bundle.ruleSets,
                'rules': [
                  ...bundle.rulesFor('block'),
                  ...bundle.rulesFor('proxy'),
                  ...bundle.rulesFor('direct'),
                ],
              }),
            )
            .length >
        maximumInlineBytes) {
      throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
    }
    return bundle;
  }
}

/// Conservative common RE2 subset, without executing provider expressions.
/// Unsupported lookaround/backrefs/named groups are not installed as rules.
void validateProviderRegex(String value) {
  try {
    validateGeoRegex(value);
  } on FormatException {
    throw const ProviderGeoException(ProviderGeoIssue.invalid);
  }
}

String canonicalProviderCidr(String input) {
  if (input.contains('%') || input.contains(' ') || input.contains('\\')) {
    throw const ProviderGeoException(ProviderGeoIssue.invalid);
  }
  final parts = input.split('/');
  if (!parts.first.contains(':') &&
      !RegExp(
        r'^(?:0|[1-9]\d{0,2})(?:\.(?:0|[1-9]\d{0,2})){3}$',
      ).hasMatch(parts.first)) {
    throw const ProviderGeoException(ProviderGeoIssue.invalid);
  }
  if (parts.length == 2 &&
      !RegExp(r'^(?:0|[1-9]\d{0,2})$').hasMatch(parts.last)) {
    throw const ProviderGeoException(ProviderGeoIssue.invalid);
  }
  final ip = InternetAddress.tryParse(parts.first);
  final prefix = parts.length == 1
      ? (ip?.type == InternetAddressType.IPv4 ? 32 : 128)
      : parts.length == 2
      ? int.tryParse(parts.last)
      : null;
  if (input.length > 80 ||
      ip == null ||
      prefix == null ||
      prefix < 0 ||
      prefix > ip.rawAddress.length * 8) {
    throw const ProviderGeoException(ProviderGeoIssue.invalid);
  }
  final bytes = ip.rawAddress.toList();
  for (var index = 0; index < bytes.length; index++) {
    final remaining = prefix - index * 8;
    if (remaining <= 0) {
      bytes[index] = 0;
    } else if (remaining < 8) {
      bytes[index] &= (255 << (8 - remaining)) & 255;
    }
  }
  return InternetAddress.fromRawAddress(Uint8List.fromList(bytes)).address +
      '/' +
      prefix.toString();
}

class ProviderGeoCompiler {
  const ProviderGeoCompiler({
    this.datLimits = const ProviderGeoDatLimits(
      maxStrings: ProviderGeoBundle.maximumStrings,
      maxStringBytes: ProviderGeoBundle.maximumInlineBytes,
    ),
  });
  final ProviderGeoDatLimits datLimits;
  ProviderGeoBundle compile(
    ProviderRoutingProfile profile, {
    required String scope,
    required String metadataDigest,
    Uint8List? geoSite,
    Uint8List? geoIp,
  }) {
    try {
      return _compile(
        profile,
        scope: scope,
        metadataDigest: metadataDigest,
        geoSite: geoSite,
        geoIp: geoIp,
      );
    } on ProviderGeoDatLimitException {
      throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
    }
  }

  ProviderGeoBundle _compile(
    ProviderRoutingProfile profile, {
    required String scope,
    required String metadataDigest,
    required Uint8List? geoSite,
    required Uint8List? geoIp,
  }) {
    final decoder = ProviderGeoDatDecoder(limits: datLimits).newSession();
    final siteCache = <String, ProviderGeoSiteCategory>{};
    final ipCache = <String, ProviderGeoIpCategory>{};
    var outputStrings = 0, outputBytes = 0;
    void retainString(String value) {
      if (++outputStrings > ProviderGeoBundle.maximumStrings ||
          (outputBytes += utf8.encode(jsonEncode(value)).length + 1) >
              ProviderGeoBundle.maximumInlineBytes) {
        throw const ProviderGeoException(ProviderGeoIssue.tooLarge);
      }
    }

    List<Map<String, dynamic>> group(
      List<ProviderRoutingRule> sites,
      List<ProviderRoutingRule> ips,
    ) {
      final domains = <String, Set<String>>{};
      final cidrs = <String>{};
      final negative = <String>{};
      final selectedSites = <String>{};
      final selectedIps = <(String, bool)>{};
      void addDomain(String field, String text) {
        if (domains.putIfAbsent(field, () => <String>{}).add(text)) {
          retainString(text);
        }
      }

      for (final site in sites) {
        switch (site.kind) {
          case ProviderRuleKind.fullDomain:
            addDomain('domain', site.value.toLowerCase());
          case ProviderRuleKind.domainSuffix:
            addDomain('domain', site.value.toLowerCase());
            addDomain('domain_suffix', '.' + site.value.toLowerCase());
          case ProviderRuleKind.keyword:
            addDomain('domain_keyword', site.value.toLowerCase());
          case ProviderRuleKind.regularExpression:
            addDomain('domain_regex', site.value);
          case ProviderRuleKind.dotless:
            addDomain(
              'domain_regex',
              r'^[^.]*' + RegExp.escape(site.value) + r'[^.]*$',
            );
          case ProviderRuleKind.geoSite:
            if (geoSite == null) {
              throw const ProviderGeoException(ProviderGeoIssue.absent);
            }
            final key = site.value.toLowerCase() + '@' + (site.attribute ?? '');
            if (!selectedSites.add(key)) break;
            final category = siteCache.putIfAbsent(
              key,
              () => decoder.decodeGeoSite(
                geoSite,
                category: site.value,
                attribute: site.attribute,
              ),
            );
            for (final rule in category.rules) {
              addDomain(switch (rule.kind) {
                ProviderGeoDomainKind.full => 'domain',
                ProviderGeoDomainKind.suffix => 'domain_suffix',
                ProviderGeoDomainKind.keyword => 'domain_keyword',
                ProviderGeoDomainKind.regex => 'domain_regex',
              }, rule.value);
            }
          default:
            throw const ProviderGeoException(ProviderGeoIssue.invalid);
        }
      }
      for (final ip in ips) {
        List<String> values;
        var inverted = ip.negated;
        if (ip.kind == ProviderRuleKind.geoIp) {
          if (geoIp == null) {
            throw const ProviderGeoException(ProviderGeoIssue.absent);
          }
          final key = ip.value.toLowerCase();
          if (!selectedIps.add((key, ip.negated))) continue;
          final category = ipCache.putIfAbsent(
            key,
            () => decoder.decodeGeoIp(geoIp, category: ip.value),
          );
          inverted = inverted != category.reverseMatch;
          values = category.cidrs
              .map((row) => canonicalProviderCidr(row.cidr))
              .toList();
        } else {
          values = [canonicalProviderCidr(ip.value)];
        }
        final target = inverted ? negative : cidrs;
        for (final value in values) {
          if (target.add(value)) retainString(value);
        }
      }
      return [
        if (domains.isNotEmpty)
          {
            for (final key in (domains.keys.toList()..sort()))
              key: domains[key]!.toList()..sort(),
          },
        if (cidrs.isNotEmpty) {'ip_cidr': cidrs.toList()..sort()},
        // Xray's inverse IP entries are an AND clause: !A AND !B equals
        // !(A OR B). Positive entries remain a separate OR alternative.
        if (negative.isNotEmpty)
          {'ip_cidr': negative.toList()..sort(), 'invert': true},
      ];
    }

    return ProviderGeoBundle.fromJson({
      'schema': 1,
      'scope': scope,
      'metadataDigest': metadataDigest,
      'groups': {
        'block': group(profile.blockSites, profile.blockIp),
        'proxy': group(profile.proxySites, profile.proxyIp),
        'direct': group(profile.directSites, profile.directIp),
      },
    });
  }
}

/// Only these policies reference packaged SRS files. Provider-only sessions
/// use their validated inline bundle and must not depend on the built-in cache.
bool usesBuiltInGeo(AppSettings settings) =>
    settings.routingMode != RoutingMode.global &&
    settings.geoRoutingMode != GeoRoutingMode.provider;

/// Platform guards remain before provider predicates. Built-in policy bytes
/// are untouched when selected; global routing ignores all geo policy.
Map<String, dynamic> composeProviderGeoRoute(
  Map<String, dynamic> original,
  AppSettings settings,
  ProviderGeoBundle? bundle, {
  bool guardProviderDirectIpv6 = false,
}) {
  if (settings.routingMode == RoutingMode.global ||
      settings.geoRoutingMode == GeoRoutingMode.builtIn)
    return original;
  if (bundle == null) {
    if (settings.geoRoutingMode == GeoRoutingMode.combined) return original;
    throw const ProviderGeoException(ProviderGeoIssue.absent);
  }
  const builtin = {'ru-blocked', 'ru-blocked-community', 're-filter', 'ru'};
  final existing = (original['rules'] as List).cast<Map<String, dynamic>>();
  final guards = existing
      .where((r) => !builtin.contains(r['rule_set']))
      .toList();
  final builtinProxy = existing
      .where((r) => builtin.contains(r['rule_set']) && r['outbound'] == 'proxy')
      .toList();
  final builtinDirect = existing
      .where((r) => builtin.contains(r['rule_set']) && r['outbound'] != 'proxy')
      .toList();
  final combined = settings.geoRoutingMode == GeoRoutingMode.combined;
  return {
    ...original,
    'rules': [
      ...guards,
      ...bundle.rulesFor('block'),
      ...bundle.rulesFor('proxy'),
      if (combined) ...builtinProxy,
      if (guardProviderDirectIpv6 && bundle.groups['direct']!.isNotEmpty)
        {
          'rule_set': bundle.tag('direct'),
          'ip_version': 6,
          'outbound': 'proxy',
        },
      ...bundle.rulesFor('direct'),
      if (combined) ...builtinDirect,
    ],
    'rule_set': [
      if (combined) ...?(original['rule_set'] as List?),
      ...bundle.ruleSets,
    ],
  };
}
