import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/provider_geo_dat_decoder.dart';

// Wholly synthetic messages from the official geodat.proto field numbers.
List<int> _varint(BigInt value) {
  final result = <int>[];
  do {
    final byte = (value & BigInt.from(127)).toInt();
    value >>= 7;
    result.add(byte | (value == BigInt.zero ? 0 : 128));
  } while (value != BigInt.zero);
  return result;
}

List<int> _number(int field, int value) => [
  ..._varint(BigInt.from(field * 8)),
  ..._varint(BigInt.from(value)),
];
List<int> _bytes(int field, List<int> bytes) => [
  ..._varint(BigInt.from(field * 8 + 2)),
  ..._varint(BigInt.from(bytes.length)),
  ...bytes,
];
List<int> _text(int field, String text) => _bytes(field, utf8.encode(text));
List<int> _attribute(String key, {int? boolValue, BigInt? intValue}) => [
  ..._text(1, key),
  if (boolValue != null) ..._number(2, boolValue),
  if (intValue != null) ..._varint(BigInt.from(24)),
  if (intValue != null) ..._varint(intValue),
];
List<int> _domain(
  int? type,
  String value, {
  List<List<int>> attrs = const [],
}) => [
  if (type != null) ..._number(1, type),
  ..._text(2, value),
  for (final attr in attrs) ..._bytes(3, attr),
];
List<int> _site(
  String code,
  List<List<int>> domains, {
  bool codeLast = false,
}) => [
  if (!codeLast) ..._text(1, code),
  for (final domain in domains) ..._bytes(2, domain),
  if (codeLast) ..._text(1, code),
];
List<int> _cidr(List<int> ip, int? prefix) => [
  ..._bytes(1, ip),
  if (prefix != null) ..._number(2, prefix),
];
List<int> _ip(String code, List<List<int>> cidrs, {bool reverse = false}) => [
  ..._text(1, code),
  for (final cidr in cidrs) ..._bytes(2, cidr),
  if (reverse) ..._number(3, 1),
];
Uint8List _file(List<List<int>> entries) =>
    Uint8List.fromList([for (final entry in entries) ..._bytes(1, entry)]);
Matcher _failure(String code) => throwsA(
  isA<FormatException>().having(
    (error) => error.message,
    'safe code',
    'provider-geo-dat:$code',
  ),
);

void main() {
  const decoder = ProviderGeoDatDecoder();

  test(
    'one DAT index serves distinct categories under a cumulative field budget',
    () {
      final input = _file([
        _site('A', [_domain(3, 'a.invalid')]),
        _site('B', [_domain(3, 'b.invalid')]),
      ]);
      final session = const ProviderGeoDatDecoder(
        limits: ProviderGeoDatLimits(maxFields: 14),
      ).newSession();
      expect(
        session.decodeGeoSite(input, category: 'a').rules.single.value,
        'a.invalid',
      );
      expect(
        session.decodeGeoSite(input, category: 'b').rules.single.value,
        'b.invalid',
      );
      final bounded = const ProviderGeoDatDecoder(
        limits: ProviderGeoDatLimits(maxFields: 13),
      ).newSession();
      bounded.decodeGeoSite(input, category: 'a');
      expect(
        () => bounded.decodeGeoSite(input, category: 'b'),
        _failure('field-limit'),
      );
    },
  );

  test(
    'category and attribute expansions share selected-record and string budgets',
    () {
      final input = _file([
        _site('A', [
          _domain(
            3,
            'same.invalid',
            attrs: [_attribute('Ads'), _attribute('ads')],
          ),
        ]),
        _site('B', [_domain(3, 'same.invalid')]),
      ]);
      final records = const ProviderGeoDatDecoder(
        limits: ProviderGeoDatLimits(maxSelectedRecords: 1),
      ).newSession();
      records.decodeGeoSite(input, category: 'a', attribute: 'Ads');
      // Category casing reuses an exact selection without spending more work.
      records.decodeGeoSite(input, category: 'A', attribute: 'Ads');
      expect(
        () => records.decodeGeoSite(input, category: 'b'),
        _failure('selected-record-limit'),
      );
      final attributes = const ProviderGeoDatDecoder(
        limits: ProviderGeoDatLimits(maxSelectedRecords: 1),
      ).newSession();
      attributes.decodeGeoSite(input, category: 'a', attribute: 'Ads');
      expect(
        () => attributes.decodeGeoSite(input, category: 'a', attribute: 'ads'),
        _failure('selected-record-limit'),
      );
      for (final attribute in [null, 'ads']) {
        final strings = const ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxStrings: 1),
        ).newSession();
        strings.decodeGeoSite(input, category: 'a', attribute: 'Ads');
        expect(
          () => strings.decodeGeoSite(
            input,
            category: attribute == null ? 'b' : 'a',
            attribute: attribute,
          ),
          _failure('string-limit'),
        );
      }
    },
  );

  test(
    'shared work scope bounds both DAT files and escaped selected bytes',
    () {
      final site = _file([
        _site('A', [_domain(3, 'a.invalid')]),
      ]);
      final ip = _file([
        _ip('B', [
          _cidr([192, 0, 2, 0], 24),
        ]),
      ]);
      final bytes = ProviderGeoDatDecoder(
        limits: ProviderGeoDatLimits(
          maxTotalFileBytes: site.length + ip.length - 1,
        ),
      ).newSession();
      bytes.decodeGeoSite(site, category: 'a');
      expect(
        () => bytes.decodeGeoIp(ip, category: 'b'),
        _failure('total-file-size'),
      );
      expect(
        () => ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxFileBytes: site.length - 1),
        ).decodeGeoSite(site, category: 'a'),
        _failure('file-size'),
      );
      final records = const ProviderGeoDatDecoder(
        limits: ProviderGeoDatLimits(maxFileRecords: 1),
      ).newSession();
      records.decodeGeoSite(site, category: 'a');
      expect(
        () => records.decodeGeoIp(ip, category: 'b'),
        _failure('file-record-limit'),
      );
      expect(
        () => const ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxStringBytes: 1),
        ).decodeGeoSite(site, category: 'a'),
        _failure('string-byte-limit'),
      );
    },
  );

  test('indexed attribute matching retains literal case', () {
    final input = _file([
      _site('A', [
        _domain(3, 'upper.invalid', attrs: [_attribute('Ads')]),
        _domain(3, 'lower.invalid', attrs: [_attribute('ads')]),
      ]),
    ]);
    final session = decoder.newSession();
    expect(
      session
          .decodeGeoSite(input, category: 'a', attribute: 'Ads')
          .rules
          .single
          .value,
      'upper.invalid',
    );
    expect(
      session
          .decodeGeoSite(input, category: 'A', attribute: 'ads')
          .rules
          .single
          .value,
      'lower.invalid',
    );
  });

  test('chosen category retains all four domain matching meanings', () {
    final result = decoder.decodeGeoSite(
      _file([
        _site('OTHER', [_domain(3, 'ignored.invalid')]),
        _site('EXAMPLE', [
          _domain(null, 'KeyWord'),
          _domain(1, r'^Foo\.invalid$'),
          _domain(2, 'Example.Invalid'),
          _domain(3, 'Only.Invalid'),
          _domain(3, 'only.invalid'),
        ], codeLast: true),
      ]),
      category: 'example',
    );
    expect(result.category, 'example');
    expect(result.rules.map((rule) => (rule.kind, rule.value)), [
      (ProviderGeoDomainKind.keyword, 'keyword'),
      (ProviderGeoDomainKind.regex, r'^Foo\.invalid$'),
      (ProviderGeoDomainKind.full, 'example.invalid'),
      (ProviderGeoDomainKind.suffix, '.example.invalid'),
      (ProviderGeoDomainKind.full, 'only.invalid'),
    ]);
    expect(() => result.rules.clear(), throwsUnsupportedError);
  });

  test(
    '@ attributes require literal keys, including !cn and false/int values',
    () {
      final input = _file([
        _site('TEST', [
          _domain(
            3,
            'both.invalid',
            attrs: [
              _attribute('!cn', boolValue: 0),
              _attribute('ads', intValue: (BigInt.one << 64) - BigInt.one),
            ],
          ),
          _domain(3, 'cn.invalid', attrs: [_attribute('cn', boolValue: 1)]),
          _domain(3, 'none.invalid'),
        ]),
      ]);
      final result = decoder.decodeGeoSite(
        input,
        category: 'TEST',
        attribute: '!cn@ads',
      );
      expect(result.attributes, ['!cn', 'ads']);
      expect(result.rules.single.value, 'both.invalid');
      expect(
        decoder
            .decodeGeoSite(input, category: 'test', attribute: 'cn')
            .rules
            .single
            .value,
        'cn.invalid',
      );
      expect(
        () => decoder.decodeGeoSite(input, category: 'test', attribute: '!ads'),
        _failure('empty-selected-category'),
      );
    },
  );

  test(
    'IPv4 and IPv6 CIDRs mask host bits and preserve reverse separately',
    () {
      final result = decoder.decodeGeoIp(
        _file([
          _ip('RU', [
            _cidr([10, 9, 8, 7], 8),
            _cidr([
              0x20,
              1,
              0x0d,
              0xb8,
              0xff,
              0xff,
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              1,
            ], 37),
            _cidr([10, 0, 0, 0], 8),
          ], reverse: true),
        ]),
        category: 'ru',
      );
      expect(result.cidrs.map((cidr) => cidr.cidr), [
        '10.0.0.0/8',
        '2001:db8:f800:0:0:0:0:0/37',
      ]);
      expect(result.reverseMatch, isTrue);
      expect(() => result.cidrs.first.network[0] = 1, throwsUnsupportedError);
    },
  );

  test('proto3 missing prefix is a valid zero-prefix network', () {
    expect(
      decoder
          .decodeGeoIp(
            _file([
              _ip('ALL', [
                _cidr([1, 2, 3, 4], null),
              ]),
            ]),
            category: 'all',
          )
          .cidrs
          .single
          .cidr,
      '0.0.0.0/0',
    );
  });

  test('missing/empty categories never become empty or inverted match-all', () {
    expect(
      () => decoder.decodeGeoSite(_file([_site('RU', [])]), category: 'cn'),
      _failure('missing-selected-category'),
    );
    expect(
      () => decoder.decodeGeoSite(_file([_site('RU', [])]), category: 'ru'),
      _failure('empty-selected-category'),
    );
    expect(
      () => decoder.decodeGeoIp(
        _file([_ip('RU', [], reverse: true)]),
        category: 'ru',
      ),
      _failure('empty-selected-category'),
    );
  });

  test(
    'duplicate selected categories and unknown domain enum fail explicitly',
    () {
      expect(
        () => decoder.decodeGeoSite(
          _file([
            _site('RU', [_domain(3, 'one.invalid')]),
            _site('ru', [_domain(3, 'two.invalid')]),
          ]),
          category: 'ru',
        ),
        _failure('duplicate-selected-category'),
      );
      expect(
        () => decoder.decodeGeoSite(
          _file([
            _site('RU', [_domain(4, 'unknown.invalid')]),
          ]),
          category: 'ru',
        ),
        _failure('unknown-domain-enum'),
      );
    },
  );

  test(
    'selectors are category/attribute data, not paths or routing negation',
    () {
      final input = _file([
        _site('geolocation-!cn', [_domain(3, 'site.invalid')]),
      ]);
      expect(
        decoder.decodeGeoSite(input, category: 'geolocation-!cn').rules,
        hasLength(1),
      );
      for (final selector in ['!ru', 'geoip:ru', '../ru', '', ' ru']) {
        expect(
          () => decoder.decodeGeoIp(input, category: selector),
          _failure('invalid-category'),
        );
      }
      for (final attr in ['', '@ads', 'cn@@ads', 'path/attr']) {
        expect(
          () => decoder.decodeGeoSite(
            input,
            category: 'geolocation-!cn',
            attribute: attr,
          ),
          _failure('invalid-attribute-selector'),
        );
      }
    },
  );

  test('invalid address sizes and IPv4/IPv6 prefixes are rejected', () {
    for (final address in [
      <int>[],
      [1, 2, 3],
      [1, 2, 3, 4, 5],
    ]) {
      expect(
        () => decoder.decodeGeoIp(
          _file([
            _ip('RU', [_cidr(address, 1)]),
          ]),
          category: 'ru',
        ),
        _failure('invalid-address-size'),
      );
    }
    for (final pair in [
      ([1, 2, 3, 4], 33),
      (List.filled(16, 0), 129),
    ]) {
      expect(
        () => decoder.decodeGeoIp(
          _file([
            _ip('RU', [_cidr(pair.$1, pair.$2)]),
          ]),
          category: 'ru',
        ),
        _failure('invalid-prefix'),
      );
    }
  });

  test(
    'truncated, overflow and invalid-wire messages fail without partial output',
    () {
      final good = _file([
        _site('RU', [_domain(3, 'ok.invalid')]),
      ]);
      expect(
        () => decoder.decodeGeoSite(
          Uint8List.sublistView(good, 0, good.length - 1),
          category: 'ru',
        ),
        _failure('truncated-field'),
      );
      expect(
        () => decoder.decodeGeoSite(Uint8List.fromList([0x80]), category: 'ru'),
        _failure('truncated-varint'),
      );
      expect(
        () => decoder.decodeGeoSite(
          Uint8List.fromList(List.filled(10, 0xff)),
          category: 'ru',
        ),
        _failure('varint-overflow'),
      );
      expect(
        () => decoder.decodeGeoSite(Uint8List.fromList([0]), category: 'ru'),
        _failure('invalid-tag'),
      );
      expect(
        () => decoder.decodeGeoSite(Uint8List.fromList([0x0b]), category: 'ru'),
        _failure('invalid-tag'),
      );
      expect(
        () => decoder.decodeGeoSite(
          Uint8List.fromList(_number(1, 1)),
          category: 'ru',
        ),
        _failure('wrong-schema-wire'),
      );
    },
  );

  test(
    'unknown noncritical fields are skipped with their length still checked',
    () {
      final input = Uint8List.fromList([
        ..._number(10, 2),
        ..._bytes(12, [1, 2, 3]),
        ..._varint(BigInt.from(13 * 8 + 1)),
        ...List.filled(8, 0),
        ..._varint(BigInt.from(14 * 8 + 5)),
        ...List.filled(4, 0),
        ..._file([
          _site('RU', [_domain(3, 'ok.invalid')]),
        ]),
      ]);
      expect(
        decoder.decodeGeoSite(input, category: 'ru').rules.single.value,
        'ok.invalid',
      );
      expect(
        () => decoder.decodeGeoSite(
          Uint8List.fromList([0x52, 5, 0]),
          category: 'ru',
        ),
        _failure('truncated-field'),
      );
    },
  );

  test('malformed UTF8, empty domain and schema-wire changes are rejected', () {
    final invalidDomain = [
      ..._number(1, 3),
      ..._bytes(2, [0xff]),
    ];
    expect(
      () => decoder.decodeGeoSite(
        _file([
          _site('RU', [invalidDomain]),
        ]),
        category: 'ru',
      ),
      _failure('invalid-utf8'),
    );
    expect(
      () => decoder.decodeGeoSite(
        _file([
          _site('RU', [_domain(3, '')]),
        ]),
        category: 'ru',
      ),
      _failure('invalid-domain-value'),
    );
    expect(
      () => decoder.decodeGeoSite(
        _file([
          _site('RU', [_number(2, 1)]),
        ]),
        category: 'ru',
      ),
      _failure('wrong-schema-wire'),
    );
  });

  test(
    'file/category/entry/field/depth/value/attribute limits are enforced',
    () {
      final plain = _file([
        _site('RU', [_domain(3, 'ok.invalid')]),
      ]);
      expect(
        () => const ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxFileBytes: 1),
        ).decodeGeoSite(plain, category: 'ru'),
        _failure('file-size'),
      );
      final two = _file([
        _site('RU', [_domain(3, 'a.invalid'), _domain(3, 'b.invalid')]),
      ]);
      expect(
        () => const ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxFileRecords: 1),
        ).decodeGeoSite(two, category: 'ru'),
        _failure('file-record-limit'),
      );
      expect(
        () => const ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxSelectedRecords: 1),
        ).decodeGeoSite(two, category: 'ru'),
        _failure('selected-record-limit'),
      );
      expect(
        () => const ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxFields: 1),
        ).decodeGeoSite(plain, category: 'ru'),
        _failure('field-limit'),
      );
      expect(
        () => const ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxValueBytes: 1),
        ).decodeGeoSite(plain, category: 'ru'),
        _failure('value-size'),
      );
      final attrs = _file([
        _site('RU', [
          _domain(
            3,
            'ok.invalid',
            attrs: [_attribute('cn'), _attribute('ads')],
          ),
        ]),
      ]);
      expect(
        () => const ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxAttributesPerDomain: 1),
        ).decodeGeoSite(attrs, category: 'ru'),
        _failure('attribute-limit'),
      );
      expect(
        () => const ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxDepth: 2),
        ).decodeGeoSite(attrs, category: 'ru'),
        _failure('depth-limit'),
      );
      final categories = _file([_site('RU', []), _site('CN', [])]);
      expect(
        () => const ProviderGeoDatDecoder(
          limits: ProviderGeoDatLimits(maxCategories: 1),
        ).decodeGeoSite(categories, category: 'ru'),
        _failure('category-limit'),
      );
    },
  );
}
