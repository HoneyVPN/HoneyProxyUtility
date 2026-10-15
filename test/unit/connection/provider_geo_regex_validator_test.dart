import 'package:flutter_test/flutter_test.dart';
import 'package:honeyproxyutility/features/connection/data/singbox/provider_geo_regex_validator.dart';

Matcher get invalid => throwsA(
  isA<FormatException>()
      .having(
        (error) => error.message,
        'stable code',
        'provider-geo-regex-invalid',
      )
      .having((error) => error.source, 'no provider text', isNull),
);

void main() {
  // These patterns were also compiled locally by Go's RE2-compatible regexp
  // compiler, and are exercised by the independent native C# fixture.
  const accepted = [
    r'(^|\.)example\.com$',
    r'^([a-z0-9-]+\.)?example\.com$',
    r'(?i)^(?:api|cdn)\d{1,3}\.test$',
    r'(?i-s:example)\.test',
    r'^[[:alpha:]][[:alnum:]_-]*\.test$',
    r'^\x41{1,1000}\x{42}+$',
    r'^\Afoo\z$',
    r'^a{0,}b{2,4}?$',
    r'(a{100}){10}',
    r'(a{1000}){0,}',
    r'(a{1000})*',
    r'((a{1000}){0}){1000}',
    r'(?U)(a+)\.test',
    r'(?-i:example)\.test',
    r'[[:^alpha:]]',
    r'[]a]',
    r'[^]a]',
    r'[\x41-\x42]',
    r'a|',
    r'(?:)',
  ];
  for (final pattern in accepted) {
    test('accept bounded portable RE2 syntax: $pattern', () {
      expect(() => validateGeoRegex(pattern), returnsNormally);
    });
  }
  const rejected = [
    r'(a)\1',
    r'\0',
    r'\k<name>',
    r'\g{1}',
    r'(?=example)',
    r'(?!example)',
    r'(?<=example)',
    r'(?<!example)',
    r'(?P<name>example)',
    r'(?<name>example)',
    r'(?>example)',
    r'(?x)example',
    r'(?i-)example',
    r'(?-:example)',
    r'a{1001}',
    r'a{2,1001}',
    r'a{2,1}',
    r'a{01}',
    r'a**',
    r'a++',
    r'[z-a]',
    r'[a-\d]',
    r'[abc',
    r'[[:unknown:]]',
    r'(abc',
    r'abc)',
    r'\q',
    r'\x1',
    r'\x{110000}',
    r'\x{d800}',
    r'\p{L}',
    r'\Qexample\E',
    r'^*',
    r'abc\',
    r'(a{1000}){2}',
    r'(a{100}){11}',
    r'((a{10}){10}){11}',
    r'((){1000}){2}',
    r'((?i){1000}){2}',
    r'((a{0}){1000}){2}',
    r'((a{1000}){0,}){2}',
  ];
  for (final pattern in rejected) {
    test('reject unsupported or malformed provider syntax: $pattern', () {
      expect(() => validateGeoRegex(pattern), invalid);
    });
  }
  test('text cap includes UTF-16 length and is enforced before parsing', () {
    expect(
      () => validateGeoRegex(List.filled(512, 'a').join()),
      returnsNormally,
    );
    expect(() => validateGeoRegex(List.filled(513, 'a').join()), invalid);
    expect(
      () => validateGeoRegex(List.filled(256, '😀').join()),
      returnsNormally,
    );
    expect(() => validateGeoRegex(List.filled(257, '😀').join()), invalid);
  });
  test('empty, whitespace, controls and lone surrogates fail safely', () {
    for (final pattern in [
      '',
      ' ',
      '\u3000',
      'a\nb',
      'a\tb',
      'a\u0085b',
      '\uD800',
      '\uDC00',
    ]) {
      expect(() => validateGeoRegex(pattern), invalid);
    }
  });
  test('group nesting is bounded independently of text length', () {
    final sixteen =
        List.filled(16, '(').join() + 'a' + List.filled(16, ')').join();
    final seventeen = '(' + sixteen + ')';
    expect(() => validateGeoRegex(sixteen), returnsNormally);
    expect(() => validateGeoRegex(seventeen), invalid);
  });
}
