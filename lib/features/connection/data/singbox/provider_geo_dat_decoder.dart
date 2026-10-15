import 'dart:convert';
import 'dart:typed_data';

/// Data-only decoder for Xray common/geodata/geodat.proto. It performs no I/O
/// and does not install routing rules or execute regular expressions.
class ProviderGeoDatDecoder {
  const ProviderGeoDatDecoder({this.limits = const ProviderGeoDatLimits()});

  final ProviderGeoDatLimits limits;

  /// One compilation shares indexing and work/output limits across both DATs
  /// and all category/attribute selections. Standalone decodes get a fresh scope.
  ProviderGeoDatSession newSession() {
    limits._validate();
    return ProviderGeoDatSession._(this);
  }

  ProviderGeoSiteCategory decodeGeoSite(
    Uint8List data, {
    required String category,
    String? attribute,
  }) => newSession().decodeGeoSite(
    data,
    category: category,
    attribute: attribute,
  );

  ProviderGeoSiteCategory _decodeGeoSite(
    _Reader selected,
    String code,
    List<String> attributes,
  ) {
    final rules = <ProviderGeoDomainRule>[];
    final seen = <String>{};
    while (!selected.done) {
      final field = selected.tag();
      if (field.number == 2) {
        _wire(field, 2);
        selected.budget.selectedRecord();
        final domain = _domain(selected.message());
        if (!attributes.every(domain.attributes.contains)) continue;
        final value = domain.type == 1
            ? domain.value
            : domain.value.toLowerCase();
        void add(ProviderGeoDomainKind kind, String value) {
          if (seen.add('${kind.name}:$value')) {
            selected.budget.string(value);
            rules.add(ProviderGeoDomainRule(kind, value));
          }
        }

        switch (domain.type) {
          case 0:
            add(ProviderGeoDomainKind.keyword, value);
          case 1:
            // RE2 compatibility belongs to future typed rule validation.
            add(ProviderGeoDomainKind.regex, value);
          case 2:
            // A leading dot means subdomains only in sing-box. Retain the
            // exact domain too; example.com must not match badexample.com.
            add(ProviderGeoDomainKind.full, value);
            add(ProviderGeoDomainKind.suffix, '.$value');
          case 3:
            add(ProviderGeoDomainKind.full, value);
        }
      } else if (field.number == 1) {
        _wire(field, 2);
        selected.string(limits.maxSelectorBytes);
      } else {
        selected.skip(field.wire);
      }
    }
    if (rules.isEmpty) _fail('empty-selected-category');
    return ProviderGeoSiteCategory(code, attributes, rules);
  }

  ProviderGeoIpCategory decodeGeoIp(
    Uint8List data, {
    required String category,
  }) => newSession().decodeGeoIp(data, category: category);

  ProviderGeoIpCategory _decodeGeoIp(_Reader selected, String code) {
    final cidrs = <ProviderGeoCidr>[];
    final seen = <String>{};
    var reverse = false;
    while (!selected.done) {
      final field = selected.tag();
      switch (field.number) {
        case 1:
          _wire(field, 2);
          selected.string(limits.maxSelectorBytes);
        case 2:
          _wire(field, 2);
          selected.budget.selectedRecord();
          final cidr = _cidr(selected.message());
          if (seen.add(cidr.cidr)) {
            selected.budget.string(cidr.cidr);
            cidrs.add(cidr);
          }
        case 3:
          _wire(field, 0);
          reverse = selected.varint() != BigInt.zero;
        default:
          selected.skip(field.wire);
      }
    }
    // An empty inverted category must never become an implicit match-all.
    if (cidrs.isEmpty) _fail('empty-selected-category');
    return ProviderGeoIpCategory(code, cidrs, reverseMatch: reverse);
  }

  _DatIndex _index(Uint8List data, _Budget budget) {
    if (data.isEmpty) _fail('file-size');
    budget.file(data.length);
    final root = _Reader(data, 0, data.length, 0, budget);
    final categories = <String, _IndexedCategory?>{};
    while (!root.done) {
      final field = root.tag();
      if (field.number != 1) {
        root.skip(field.wire);
        continue;
      }
      _wire(field, 2);
      budget.category();
      final entry = root.message();
      final start = entry.offset;
      String? code;
      while (!entry.done) {
        final child = entry.tag();
        if (child.number == 1) {
          _wire(child, 2);
          code = _category(entry.string(limits.maxSelectorBytes));
        } else if (child.number == 2) {
          _wire(child, 2);
          budget.fileRecord();
          entry.skip(2);
        } else {
          entry.skip(child.wire);
        }
      }
      if (code != null) {
        // Unselected duplicate categories stay irrelevant, as before. Selecting
        // one is an explicit error, never an arbitrary first/last entry choice.
        categories[code] = categories.containsKey(code)
            ? null
            : _IndexedCategory(start, entry.end, entry.depth);
      }
    }
    return _DatIndex(data, categories);
  }

  _Domain _domain(_Reader reader) {
    var type = 0; // The proto3 default is Substr, even when field1 is absent.
    String? value;
    final attributes = <String>{};
    var count = 0;
    while (!reader.done) {
      final field = reader.tag();
      switch (field.number) {
        case 1:
          _wire(field, 0);
          final n = reader.varint();
          if (n > BigInt.from(3)) _fail('unknown-domain-enum');
          type = n.toInt();
        case 2:
          _wire(field, 2);
          value = reader.string(limits.maxValueBytes);
        case 3:
          _wire(field, 2);
          if (++count > limits.maxAttributesPerDomain) _fail('attribute-limit');
          attributes.add(_attribute(reader.message()));
        default:
          reader.skip(field.wire);
      }
    }
    if (value == null ||
        value.isEmpty ||
        value.trim() != value ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      _fail('invalid-domain-value');
    }
    return _Domain(type, value, attributes);
  }

  String _attribute(_Reader reader) {
    String? key;
    while (!reader.done) {
      final field = reader.tag();
      if (field.number == 1) {
        _wire(field, 2);
        key = reader.string(limits.maxSelectorBytes);
      } else if (field.number == 2 || field.number == 3) {
        _wire(field, 0);
        // Protobuf bool/int64 values are consumed, not used for selection.
        // Xray filters by literal key presence, including !cn and bool=false.
        reader.varint();
      } else {
        reader.skip(field.wire);
      }
    }
    if (key == null || !_attributeKey.hasMatch(key)) _fail('invalid-attribute');
    return key;
  }

  ProviderGeoCidr _cidr(_Reader reader) {
    Uint8List? bytes;
    var prefix = 0;
    while (!reader.done) {
      final field = reader.tag();
      if (field.number == 1) {
        _wire(field, 2);
        bytes = reader.bytes(16);
      } else if (field.number == 2) {
        _wire(field, 0);
        final n = reader.varint();
        if (n > BigInt.from(128)) _fail('invalid-prefix');
        prefix = n.toInt();
      } else {
        reader.skip(field.wire);
      }
    }
    if (bytes == null || (bytes.length != 4 && bytes.length != 16)) {
      _fail('invalid-address-size');
    }
    if (prefix > bytes.length * 8) _fail('invalid-prefix');
    final network = bytes.toList();
    for (var i = 0; i < network.length; i++) {
      final remaining = prefix - i * 8;
      if (remaining <= 0) {
        network[i] = 0;
      } else if (remaining < 8) {
        network[i] &= (0xff << (8 - remaining)) & 0xff;
      }
    }
    return ProviderGeoCidr(network, prefix);
  }

  String _category(String input) {
    if (input.length > limits.maxSelectorBytes ||
        !_categoryKey.hasMatch(input) ||
        utf8.encode(input).length > limits.maxSelectorBytes) {
      _fail('invalid-category');
    }
    return input.toLowerCase();
  }

  List<String> _attributes(String? input) {
    if (input == null) return const [];
    if (input.length > limits.maxSelectorBytes)
      _fail('invalid-attribute-selector');
    final parts = input.split('@');
    if (parts.length > limits.maxAttributesPerDomain ||
        utf8.encode(input).length > limits.maxSelectorBytes ||
        parts.any((part) => !_attributeKey.hasMatch(part))) {
      _fail('invalid-attribute-selector');
    }
    return parts.toSet().toList();
  }

  static final _categoryKey = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.!-]*$');
  static final _attributeKey = RegExp(r'^[A-Za-z0-9_!.\-]+$');
}

class ProviderGeoDatLimits {
  const ProviderGeoDatLimits({
    this.maxFileBytes = 32 * 1024 * 1024,
    this.maxTotalFileBytes = 64 * 1024 * 1024,
    this.maxCategories = 8192,
    // The official 2026-10 geoip.dat contains 1.38 million records across all
    // countries; selection and emitted inline rules keep their smaller caps.
    this.maxFileRecords = 2000000,
    this.maxSelectedRecords = 100000,
    this.maxFields = 3000000,
    this.maxDepth = 4,
    this.maxValueBytes = 4096,
    this.maxSelectorBytes = 128,
    this.maxAttributesPerDomain = 32,
    this.maxStrings = 100000,
    this.maxStringBytes = 64 * 1024 * 1024,
  });
  final int maxFileBytes, maxTotalFileBytes;
  final int maxCategories, maxFileRecords, maxSelectedRecords;
  final int maxFields, maxDepth, maxValueBytes, maxSelectorBytes;
  final int maxAttributesPerDomain;
  final int maxStrings, maxStringBytes;

  void _validate() {
    if ([
      maxFileBytes,
      maxTotalFileBytes,
      maxCategories,
      maxFileRecords,
      maxSelectedRecords,
      maxFields,
      maxDepth,
      maxValueBytes,
      maxSelectorBytes,
      maxAttributesPerDomain,
      maxStrings,
      maxStringBytes,
    ].any((value) => value <= 0)) {
      _fail('invalid-limits');
    }
  }
}

/// A bounded, data-only compilation scope. It owns no files or network work.
class ProviderGeoDatSession {
  ProviderGeoDatSession._(this._decoder) : _budget = _Budget(_decoder.limits);
  final ProviderGeoDatDecoder _decoder;
  final _Budget _budget;
  final _indices = Map<Uint8List, _DatIndex>.identity();
  final _sites = <(Uint8List, String, String?), ProviderGeoSiteCategory>{};
  final _ips = <(Uint8List, String), ProviderGeoIpCategory>{};

  _Reader _selected(Uint8List data, String category) {
    final index = _indices.putIfAbsent(
      data,
      () => _decoder._index(data, _budget),
    );
    if (!index.categories.containsKey(category))
      _fail('missing-selected-category');
    final selected = index.categories[category];
    if (selected == null) _fail('duplicate-selected-category');
    return _Reader(
      index.data,
      selected.start,
      selected.end,
      selected.depth,
      _budget,
    );
  }

  ProviderGeoSiteCategory decodeGeoSite(
    Uint8List data, {
    required String category,
    String? attribute,
  }) {
    final code = _decoder._category(category);
    final attributes = _decoder._attributes(attribute);
    return _sites.putIfAbsent((
      data,
      code,
      attribute,
    ), () => _decoder._decodeGeoSite(_selected(data, code), code, attributes));
  }

  ProviderGeoIpCategory decodeGeoIp(
    Uint8List data, {
    required String category,
  }) {
    final code = _decoder._category(category);
    return _ips.putIfAbsent((
      data,
      code,
    ), () => _decoder._decodeGeoIp(_selected(data, code), code));
  }
}

class _IndexedCategory {
  _IndexedCategory(this.start, this.end, this.depth);
  final int start, end, depth;
}

class _DatIndex {
  _DatIndex(this.data, this.categories);
  final Uint8List data;
  final Map<String, _IndexedCategory?> categories;
}

/// A resource limit is distinct from malformed protobuf or missing selectors.
class ProviderGeoDatLimitException extends FormatException {
  ProviderGeoDatLimitException(String code) : super('provider-geo-dat:$code');
}

enum ProviderGeoDomainKind { keyword, regex, suffix, full }

class ProviderGeoDomainRule {
  const ProviderGeoDomainRule(this.kind, this.value);
  final ProviderGeoDomainKind kind;
  final String value;
}

class ProviderGeoSiteCategory {
  ProviderGeoSiteCategory(
    this.category,
    List<String> attributes,
    List<ProviderGeoDomainRule> rules,
  ) : attributes = List.unmodifiable(attributes),
      rules = List.unmodifiable(rules);
  final String category;
  final List<String> attributes;
  final List<ProviderGeoDomainRule> rules;
}

class ProviderGeoCidr {
  ProviderGeoCidr(List<int> network, this.prefix)
    : network = List.unmodifiable(network);
  final List<int> network;
  final int prefix;

  String get cidr {
    final address = network.length == 4
        ? network.join('.')
        : [
            for (var i = 0; i < 16; i += 2)
              ((network[i] << 8) | network[i + 1]).toRadixString(16),
          ].join(':');
    return '$address/$prefix';
  }
}

class ProviderGeoIpCategory {
  ProviderGeoIpCategory(
    this.category,
    List<ProviderGeoCidr> cidrs, {
    required this.reverseMatch,
  }) : cidrs = List.unmodifiable(cidrs);
  final String category;
  final List<ProviderGeoCidr> cidrs;
  // Retain this DAT bit separately. Caller routing-negation/grouping is not
  // composed here; a category never installs an action, outbound or rule-set.
  final bool reverseMatch;
}

class _Domain {
  _Domain(this.type, this.value, this.attributes);
  final int type;
  final String value;
  final Set<String> attributes;
}

class _Budget {
  _Budget(this.limits);
  final ProviderGeoDatLimits limits;
  var fields = 0;
  var _fileBytes = 0, _categories = 0, _fileRecords = 0, _selectedRecords = 0;
  var _strings = 0, _stringBytes = 0;

  void file(int bytes) {
    if (bytes > limits.maxFileBytes) _limit('file-size');
    if ((_fileBytes += bytes) > limits.maxTotalFileBytes)
      _limit('total-file-size');
  }

  void category() {
    if (++_categories > limits.maxCategories) _limit('category-limit');
  }

  void fileRecord() {
    if (++_fileRecords > limits.maxFileRecords) _limit('file-record-limit');
  }

  void selectedRecord() {
    if (++_selectedRecords > limits.maxSelectedRecords)
      _limit('selected-record-limit');
  }

  void string(String value) {
    if (++_strings > limits.maxStrings) _limit('string-limit');
    // Count JSON's escaping too, before retaining expanded selected strings.
    if ((_stringBytes += utf8.encode(jsonEncode(value)).length + 1) >
        limits.maxStringBytes) {
      _limit('string-byte-limit');
    }
  }
}

class _Tag {
  _Tag(this.number, this.wire);
  final int number, wire;
}

class _Reader {
  _Reader(this.data, this.offset, this.end, this.depth, this.budget) {
    if (depth > budget.limits.maxDepth) _fail('depth-limit');
  }
  final Uint8List data;
  int offset;
  final int end, depth;
  final _Budget budget;
  bool get done => offset == end;

  BigInt varint() {
    var result = BigInt.zero;
    for (var i = 0; i < 10; i++) {
      if (offset >= end) _fail('truncated-varint');
      final byte = data[offset++];
      if (i == 9 && byte > 1) _fail('varint-overflow');
      result |= BigInt.from(byte & 0x7f) << (i * 7);
      if (byte < 0x80) return result;
    }
    _fail('varint-overflow');
  }

  _Tag tag() {
    if (++budget.fields > budget.limits.maxFields) _limit('field-limit');
    final value = varint();
    if (value > BigInt.from(0xffffffff)) _fail('invalid-tag');
    final tag = value.toInt();
    final number = tag ~/ 8;
    final wire = tag & 7;
    if (number == 0 || wire == 3 || wire == 4 || wire > 5) _fail('invalid-tag');
    return _Tag(number, wire);
  }

  int _length() {
    final length = varint();
    if (length > BigInt.from(end - offset)) _fail('truncated-field');
    return length.toInt();
  }

  _Reader message() {
    final length = _length();
    final start = offset;
    offset += length;
    return _Reader(data, start, offset, depth + 1, budget);
  }

  Uint8List bytes(int maximum) {
    final length = _length();
    if (length > maximum) _fail('value-size');
    final start = offset;
    offset += length;
    return Uint8List.sublistView(data, start, offset);
  }

  String string(int maximum) {
    final value = bytes(maximum);
    try {
      return utf8.decode(value, allowMalformed: false);
    } on FormatException {
      _fail('invalid-utf8');
    }
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        _advance(8);
      case 2:
        _advance(_length());
      case 5:
        _advance(4);
      default:
        _fail('invalid-wire');
    }
  }

  void _advance(int bytes) {
    if (bytes > end - offset) _fail('truncated-field');
    offset += bytes;
  }
}

void _wire(_Tag tag, int expected) {
  if (tag.wire != expected) _fail('wrong-schema-wire');
}

Never _fail(String code) => throw FormatException('provider-geo-dat:$code');
Never _limit(String code) => throw ProviderGeoDatLimitException(code);
