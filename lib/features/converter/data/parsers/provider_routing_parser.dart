import 'dart:convert';

import '../../../subscriptions/domain/entities/provider_routing_metadata.dart';

enum ProviderRoutingIssue { size, encoding, link, json, schema, rule, scope }

/// Stable codes only: errors must never print provider URLs, bodies or tokens.
class ProviderRoutingParseException implements Exception {
  const ProviderRoutingParseException(
    this.issue, {
    this.declarationPresent = false,
  });
  final ProviderRoutingIssue issue;

  /// Lets callers distinguish malformed declared rules from an ancillary body
  /// size cap on a plain proxy feed that contains no provider policy.
  final bool declarationPresent;
  @override
  String toString() => 'providerRouting:${issue.name}';
}

/// Pure Happ routing envelope parser. No I/O, settings mutation or core output.
/// Docs: HappDev/happ_su/dev-docs/routing.md and Xray routing domain/IP syntax.
class ProviderRoutingParser {
  const ProviderRoutingParser();
  static const maximumBodyBytes = 2 * 1024 * 1024;
  static const maximumProfileBytes = 64 * 1024;
  static const maximumCommands = 16;
  static const maximumRules = 4096;
  static const _dnsFields = {
    'RemoteDNSType', 'RemoteDNSDomain', 'RemoteDNSIP',
    'DomesticDNSType', 'DomesticDNSDomain', 'DomesticDNSIP',
    // Legacy declarations occur in the official example HTTP header.
    'RemoteDns', 'DomesticDns',
  };
  static const _fields = {
    'Name',
    'GlobalProxy',
    'FakeDNS',
    'DomainStrategy',
    'LastUpdated',
    'Geoipurl',
    'Geositeurl',
    'RouteOrder',
    'UseChunkFiles',
    'DnsHosts',
    'DirectSites',
    'ProxySites',
    'BlockSites',
    'DirectIp',
    'ProxyIp',
    'BlockIp',
    ..._dnsFields,
  };
  static final _control = RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]');

  Never _fail(ProviderRoutingIssue issue) =>
      throw ProviderRoutingParseException(issue);

  ProviderRoutingEnvelope parse({
    required int subscriptionId,
    required String body,
    Map<String, List<String>> headers = const {},
  }) {
    if (subscriptionId <= 0) _fail(ProviderRoutingIssue.scope);
    if (utf8.encode(body).length > maximumBodyBytes) {
      _fail(ProviderRoutingIssue.size);
    }
    final commands = <ProviderRoutingCommand>[];
    final seen = <String>{};
    void add(String link) {
      ProviderRoutingCommand command;
      try {
        command = _link(link.trim());
      } on ProviderRoutingParseException catch (error) {
        throw ProviderRoutingParseException(
          error.issue,
          declarationPresent: true,
        );
      }
      if (seen.add(jsonEncode(command.toJson()))) commands.add(command);
      if (commands.length > maximumCommands) {
        throw const ProviderRoutingParseException(
          ProviderRoutingIssue.size,
          declarationPresent: true,
        );
      }
    }

    final routingHeaders = headers.entries
        .where((e) => e.key.toLowerCase() == 'routing')
        .toList();
    if (routingHeaders.length > 1 ||
        (routingHeaders.isNotEmpty &&
            routingHeaders.single.value.length != 1)) {
      _fail(ProviderRoutingIssue.schema);
    }
    if (routingHeaders.isNotEmpty) {
      final header = routingHeaders.single.value.single;
      if (_control.hasMatch(header)) _fail(ProviderRoutingIssue.link);
      add(header);
    }

    final clean = body.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
    var decoded = clean;
    var base64Decoded = false;
    final compact = clean.replaceAll(RegExp(r'\s+'), '');
    if (compact.isNotEmpty &&
        RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(compact)) {
      try {
        final candidate = utf8.decode(base64.decode(base64.normalize(compact)));
        // Do not alter ordinary encoded proxy feeds without routing metadata.
        if (candidate.contains('happ://routing/')) {
          decoded = candidate.trim().replaceFirst(RegExp(r'^\uFEFF'), '');
          base64Decoded = true;
        }
      } on FormatException {
        // The existing proxy parser owns malformed ordinary proxy bodies.
      }
    }
    final proxyLines = <String>[];
    var removed = false;
    for (final line in decoded.split(RegExp(r'\r?\n'))) {
      final text = line.trim();
      if (text.startsWith('happ://routing/')) {
        add(text);
        removed = true;
      } else {
        proxyLines.add(line);
      }
    }
    return ProviderRoutingEnvelope(
      metadata: ProviderRoutingMetadata(
        subscriptionId: subscriptionId,
        commands: commands,
      ),
      proxyBody: removed ? proxyLines.join('\n').trim() : body,
      base64BodyDecoded: base64Decoded && removed,
    );
  }

  /// Future storage can reuse the same validation and must bind the selected
  /// subscription identity. This method does not read or write storage.
  ProviderRoutingMetadata parseStored(
    Map<String, Object?> value, {
    required int subscriptionId,
  }) {
    if (subscriptionId <= 0 || value['subscriptionId'] != subscriptionId) {
      _fail(ProviderRoutingIssue.scope);
    }
    if (value.keys.any(
          (k) => !{'schema', 'subscriptionId', 'commands'}.contains(k),
        ) ||
        value['schema'] != 1 ||
        value['commands'] is! List) {
      _fail(ProviderRoutingIssue.schema);
    }
    final rows = value['commands'] as List;
    if (rows.length > maximumCommands) _fail(ProviderRoutingIssue.size);
    final result = <ProviderRoutingCommand>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic> ||
          row.keys.any((k) => !{'operation', 'profile'}.contains(k))) {
        _fail(ProviderRoutingIssue.schema);
      }
      final op = switch (row['operation']) {
        'add' => ProviderRoutingOperation.add,
        'onadd' => ProviderRoutingOperation.onadd,
        'off' => ProviderRoutingOperation.off,
        _ => _fail(ProviderRoutingIssue.schema),
      };
      if (op == ProviderRoutingOperation.off) {
        if (row.containsKey('profile')) _fail(ProviderRoutingIssue.schema);
        result.add(
          const ProviderRoutingCommand(operation: ProviderRoutingOperation.off),
        );
      } else {
        final profile = row['profile'];
        if (profile is! Map<String, dynamic>)
          _fail(ProviderRoutingIssue.schema);
        result.add(
          ProviderRoutingCommand(operation: op, profile: _profile(profile)),
        );
      }
    }
    return ProviderRoutingMetadata(
      subscriptionId: subscriptionId,
      commands: result,
    );
  }

  ProviderRoutingCommand _link(String link) {
    if (utf8.encode(link).length > maximumProfileBytes * 4 ~/ 3 + 128) {
      _fail(ProviderRoutingIssue.size);
    }
    if (_control.hasMatch(link)) _fail(ProviderRoutingIssue.link);
    if (link == 'happ://routing/off') {
      return const ProviderRoutingCommand(
        operation: ProviderRoutingOperation.off,
      );
    }
    final ProviderRoutingOperation operation;
    final String encoded;
    if (link.startsWith('happ://routing/onadd/')) {
      operation = ProviderRoutingOperation.onadd;
      encoded = link.substring('happ://routing/onadd/'.length);
    } else if (link.startsWith('happ://routing/add/')) {
      operation = ProviderRoutingOperation.add;
      encoded = link.substring('happ://routing/add/'.length);
    } else {
      _fail(ProviderRoutingIssue.link);
    }
    String payload;
    try {
      payload = Uri.decodeComponent(encoded);
      if (payload.isEmpty ||
          !RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(payload)) {
        _fail(ProviderRoutingIssue.encoding);
      }
      final bytes = base64.decode(base64.normalize(payload));
      if (bytes.length > maximumProfileBytes) _fail(ProviderRoutingIssue.size);
      payload = utf8.decode(bytes);
    } on FormatException {
      _fail(ProviderRoutingIssue.encoding);
    } on ArgumentError {
      // Uri.decodeComponent rejects malformed percent escapes with ArgumentError.
      _fail(ProviderRoutingIssue.encoding);
    }
    Object? object;
    try {
      _JsonShapeGuard(payload).check();
      object = jsonDecode(payload);
    } on ProviderRoutingParseException {
      rethrow;
    } catch (_) {
      _fail(ProviderRoutingIssue.json);
    }
    if (object is! Map<String, dynamic>) _fail(ProviderRoutingIssue.schema);
    return ProviderRoutingCommand(
      operation: operation,
      profile: _profile(object),
    );
  }

  String? _optionalText(Object? value, {int limit = 8192}) {
    if (value == null) return null;
    if (value is! String ||
        utf8.encode(value).length > limit ||
        _control.hasMatch(value)) {
      _fail(ProviderRoutingIssue.schema);
    }
    return value.isEmpty ? null : value;
  }

  bool? _boolean(Object? value) => switch (value) {
    null || '' => null,
    true || 'true' => true,
    false || 'false' => false,
    _ => _fail(ProviderRoutingIssue.schema),
  };

  String? _geoUrl(Object? value) {
    final text = _optionalText(value);
    if (text == null) return null;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535 ||
        text.contains('\\') ||
        RegExp(r'%(?![a-fA-F0-9]{2})').hasMatch(text) ||
        RegExp(r'^https://[^/?#]*:(?:[/?#]|$)').hasMatch(text) ||
        RegExp(r'\s').hasMatch(text)) {
      _fail(ProviderRoutingIssue.schema);
    }
    return text;
  }

  ProviderRoutingProfile _profile(Map<String, dynamic> value) {
    // Remnawave's public Happ builder accepts these legacy casing variants.
    // Canonicalize a copy; conflicting duplicates never pick an arbitrary URL.
    value = Map<String, dynamic>.of(value);
    const aliases = {
      'GeoipUrl': 'Geoipurl',
      'GeositeUrl': 'Geositeurl',
      'FakeDns': 'FakeDNS',
      'DomesticDNSIp': 'DomesticDNSIP',
      'RemoteDNSIp': 'RemoteDNSIP',
      'useChunkFiles': 'UseChunkFiles',
    };
    for (final entry in aliases.entries) {
      if (!value.containsKey(entry.key)) continue;
      final alias = value.remove(entry.key);
      if (value.containsKey(entry.value) && value[entry.value] != alias) {
        _fail(ProviderRoutingIssue.schema);
      }
      value[entry.value] = alias;
    }
    String serialized;
    try {
      serialized = jsonEncode(value);
    } catch (_) {
      _fail(ProviderRoutingIssue.schema);
    }
    if (utf8.encode(serialized).length > maximumProfileBytes) {
      _fail(ProviderRoutingIssue.size);
    }
    if (value.keys.any((k) => !_fields.contains(k)))
      _fail(ProviderRoutingIssue.schema);
    var count = 0;
    List<ProviderRoutingRule> rules(String field, bool ip) {
      final list = value[field];
      if (list == null) return const [];
      if (list is! List) _fail(ProviderRoutingIssue.schema);
      count += list.length;
      if (count > maximumRules) _fail(ProviderRoutingIssue.size);
      return list.map((item) {
        final text = _optionalText(item, limit: 2048);
        if (text == null) _fail(ProviderRoutingIssue.rule);
        return ip ? _ipRule(text) : _siteRule(text);
      }).toList();
    }

    final directSites = rules('DirectSites', false);
    final proxySites = rules('ProxySites', false);
    final blockSites = rules('BlockSites', false);
    final directIp = rules('DirectIp', true);
    final proxyIp = rules('ProxyIp', true);
    final blockIp = rules('BlockIp', true);
    int? revision;
    final rawRevision = value['LastUpdated'];
    if (rawRevision != null && rawRevision != '') {
      revision = rawRevision is int
          ? rawRevision
          : rawRevision is String &&
                RegExp(r'^[0-9]{1,16}$').hasMatch(rawRevision)
          ? int.tryParse(rawRevision)
          : null;
      if (revision == null || revision < 0 || revision > 9007199254740991) {
        _fail(ProviderRoutingIssue.schema);
      }
    }
    final dns = <String, String>{};
    for (final key in _dnsFields) {
      final text = _optionalText(value[key]);
      if (text != null) dns[key] = text;
    }
    final hosts = <String, String>{};
    if (value['DnsHosts'] != null) {
      final source = value['DnsHosts'];
      if (source is! Map<String, dynamic> || source.length > 128)
        _fail(ProviderRoutingIssue.schema);
      for (final entry in source.entries) {
        if (!_domain(entry.key)) _fail(ProviderRoutingIssue.schema);
        final text = _optionalText(entry.value, limit: 128);
        if (text == null || !_address(text)) _fail(ProviderRoutingIssue.schema);
        hosts[entry.key] = text;
      }
    }
    final strategy = _optionalText(value['DomainStrategy'], limit: 32);
    final routeOrder = _optionalText(value['RouteOrder'], limit: 32);
    if (routeOrder != null && routeOrder != 'block-proxy-direct') {
      _fail(ProviderRoutingIssue.schema);
    }
    if (strategy != null &&
        !{'AsIs', 'IPIfNonMatch', 'IPOnDemand'}.contains(strategy)) {
      _fail(ProviderRoutingIssue.schema);
    }
    return ProviderRoutingProfile(
      name: _optionalText(value['Name'], limit: 512),
      geoIpUrl: _geoUrl(value['Geoipurl']),
      geoSiteUrl: _geoUrl(value['Geositeurl']),
      lastUpdatedUnix: revision,
      declarations: ProviderRoutingDeclarations(
        globalProxy: _boolean(value['GlobalProxy']),
        fakeDns: _boolean(value['FakeDNS']),
        domainStrategy: strategy,
        routeOrder: routeOrder,
        preferChunkFiles: _boolean(value['UseChunkFiles']),
        dns: dns,
        dnsHosts: hosts,
      ),
      directSites: directSites,
      proxySites: proxySites,
      blockSites: blockSites,
      directIp: directIp,
      proxyIp: proxyIp,
      blockIp: blockIp,
    );
  }

  ProviderRoutingRule _siteRule(String source) {
    final colon = source.indexOf(':');
    final prefix = colon < 0 ? 'keyword' : source.substring(0, colon);
    final value = colon < 0 ? source : source.substring(colon + 1);
    if (value.isEmpty) _fail(ProviderRoutingIssue.rule);
    final kind = switch (prefix) {
      'full' => ProviderRuleKind.fullDomain,
      'domain' => ProviderRuleKind.domainSuffix,
      'keyword' => ProviderRuleKind.keyword,
      'regexp' => ProviderRuleKind.regularExpression,
      'dotless' => ProviderRuleKind.dotless,
      'geosite' => ProviderRuleKind.geoSite,
      _ => _fail(ProviderRoutingIssue.rule),
    };
    if ((kind == ProviderRuleKind.fullDomain ||
            kind == ProviderRuleKind.domainSuffix) &&
        !_domain(value)) {
      _fail(ProviderRoutingIssue.rule);
    }
    if (kind == ProviderRuleKind.dotless && value.contains('.'))
      _fail(ProviderRoutingIssue.rule);
    String? attribute;
    var category = value;
    if (kind == ProviderRuleKind.geoSite) {
      final parts = value.split('@');
      if (parts.length > 17 || !_categoryTag(parts.first))
        _fail(ProviderRoutingIssue.rule);
      category = parts.first;
      if (parts.length > 1) {
        if (parts.skip(1).any((key) => !_tag(key))) {
          _fail(ProviderRoutingIssue.rule);
        }
        attribute = parts.skip(1).join('@');
        if (attribute.length > 128) _fail(ProviderRoutingIssue.rule);
      }
    }
    // Regex text is retained, never compiled/executed in the importing UI.
    return ProviderRoutingRule(
      source: source,
      kind: kind,
      value: category,
      attribute: attribute,
    );
  }

  ProviderRoutingRule _ipRule(String source) {
    final negated = source.startsWith('!');
    final value = negated ? source.substring(1) : source;
    if (value.startsWith('geoip:')) {
      final tag = value.substring(6);
      if (!_categoryTag(tag)) _fail(ProviderRoutingIssue.rule);
      return ProviderRoutingRule(
        source: source,
        kind: ProviderRuleKind.geoIp,
        value: tag,
        negated: negated,
      );
    }
    final parts = value.split('/');
    if (parts.length > 2 || !_address(parts.first))
      _fail(ProviderRoutingIssue.rule);
    if (parts.length == 2) {
      final bits = int.tryParse(parts.last);
      if (!RegExp(r'^[0-9]{1,3}$').hasMatch(parts.last) ||
          bits == null ||
          bits < 0 ||
          bits > (parts.first.contains(':') ? 128 : 32))
        _fail(ProviderRoutingIssue.rule);
    }
    return ProviderRoutingRule(
      source: source,
      kind: parts.length == 2
          ? ProviderRuleKind.ipNetwork
          : ProviderRuleKind.ipAddress,
      value: value,
      negated: negated,
    );
  }

  static bool _tag(String value) =>
      RegExp(r'^[a-zA-Z0-9_!.\-]{1,128}$').hasMatch(value);
  static bool _categoryTag(String value) =>
      RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_!.\-]{0,127}$').hasMatch(value);
  static bool _domain(String value) =>
      value.length <= 253 &&
      value
          .split('.')
          .every(
            (label) => RegExp(
              r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
            ).hasMatch(label),
          );
  static bool _ipv4(String value) =>
      value.split('.').length == 4 &&
      value
          .split('.')
          .every(
            (s) =>
                RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(s) &&
                int.parse(s) <= 255,
          );
  static bool _address(String value) {
    if (!value.contains(':')) return _ipv4(value);
    if (value.contains('.') && value.contains(':')) {
      final last = value.lastIndexOf(':');
      if (!_ipv4(value.substring(last + 1))) return false;
      value = '${value.substring(0, last + 1)}0:0';
    }
    final halves = value.split('::');
    if (halves.length > 2) return false;
    final groups = halves
        .expand((half) => half.isEmpty ? <String>[] : half.split(':'))
        .toList();
    return groups.every((s) => RegExp(r'^[a-fA-F0-9]{1,4}$').hasMatch(s)) &&
        (halves.length == 2 ? groups.length < 8 : groups.length == 8);
  }
}

/// Detect duplicate decoded keys and bound nesting before jsonDecode discards
/// duplicate keys. JSON grammar/value decoding remains Dart's responsibility.
class _JsonShapeGuard {
  _JsonShapeGuard(this.text);
  final String text;
  int index = 0, nodes = 0;
  Never bad() =>
      throw const ProviderRoutingParseException(ProviderRoutingIssue.json);
  void space() {
    while (index < text.length && ' \r\n\t'.contains(text[index])) {
      index++;
    }
  }

  String string() {
    final start = index++;
    while (index < text.length) {
      final c = text[index++];
      if (c == '\\') {
        index++;
        continue;
      }
      if (c == '"') return jsonDecode(text.substring(start, index)) as String;
    }
    bad();
  }

  void value(int depth) {
    if (depth > 16 || ++nodes > 16384) bad();
    space();
    if (index >= text.length) bad();
    final c = text[index++];
    if (c == '"') {
      index--;
      string();
      return;
    }
    if (c == '{' || c == '[') {
      final end = c == '{' ? '}' : ']';
      final keys = <String>{};
      space();
      if (index < text.length && text[index] == end) {
        index++;
        return;
      }
      while (true) {
        space();
        if (c == '{') {
          if (index >= text.length || text[index] != '"' || !keys.add(string()))
            bad();
          space();
          if (index >= text.length || text[index++] != ':') bad();
        }
        value(depth + 1);
        space();
        if (index >= text.length) bad();
        final separator = text[index++];
        if (separator == end) return;
        if (separator != ',') bad();
      }
    }
    while (index < text.length && !',]} \r\n\t'.contains(text[index])) {
      index++;
    }
  }

  void check() {
    value(0);
    space();
    if (index != text.length) bad();
  }
}
