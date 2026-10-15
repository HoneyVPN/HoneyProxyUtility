/// Validate a bounded common RE2 subset without executing a provider pattern.
///
/// This grammar mirrors the independent Windows service boundary. Unsupported
/// syntax fails with one stable code; no pattern text is included in errors.
void validateGeoRegex(String pattern) {
  if (pattern.isEmpty || pattern.length > 512) _invalid();
  var whitespaceOnly = true;
  for (var index = 0; index < pattern.length; index++) {
    final unit = pattern.codeUnitAt(index);
    if (unit <= 0x1f || (unit >= 0x7f && unit <= 0x9f)) _invalid();
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= pattern.length) _invalid();
      final low = pattern.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) _invalid();
      whitespaceOnly = false;
    } else {
      if (unit >= 0xdc00 && unit <= 0xdfff) _invalid();
      if (!_whitespace(unit)) whitespaceOnly = false;
    }
  }
  if (whitespaceOnly) _invalid();
  _RegexSubset(pattern).validate();
}

Never _invalid() => throw const FormatException('provider-geo-regex-invalid');

bool _whitespace(int unit) =>
    unit == 0x20 ||
    unit == 0x85 ||
    unit == 0xa0 ||
    unit == 0x1680 ||
    (unit >= 0x2000 && unit <= 0x200a) ||
    unit == 0x2028 ||
    unit == 0x2029 ||
    unit == 0x202f ||
    unit == 0x205f ||
    unit == 0x3000;

bool _alphaNumeric(int unit) =>
    (unit >= 0x61 && unit <= 0x7a) ||
    (unit >= 0x41 && unit <= 0x5a) ||
    (unit >= 0x30 && unit <= 0x39);

class _RegexAtom {
  const _RegexAtom(this.repeatable, this.expansion);
  final bool repeatable;
  final int expansion;
}

class _RegexRepeat {
  const _RegexRepeat(this.count, {this.empty = false});
  final int count;
  final bool empty;
}

class _RegexSubset {
  _RegexSubset(this.pattern);
  final String pattern;
  var position = 0;
  var depth = 0;

  void validate() {
    _expression(grouped: false);
    if (position != pattern.length) _invalid();
  }

  int _expression({required bool grouped}) {
    var expansion = 0;
    while (position < pattern.length && pattern[position] != ')') {
      if (pattern[position] == '|') {
        position++;
        continue;
      }
      final atom = _atom();
      var atomExpansion = atom.expansion;
      if (position < pattern.length && _quantifier(pattern[position])) {
        if (!atom.repeatable) _invalid();
        final repeat = _repeat();
        if (repeat.empty) {
          atomExpansion = 0;
        } else {
          if (atomExpansion < 1) atomExpansion = 1;
          if (atomExpansion > 1000 ~/ repeat.count) _invalid();
          atomExpansion *= repeat.count;
        }
        if (position < pattern.length && pattern[position] == '?') position++;
        if (position < pattern.length && _quantifier(pattern[position])) {
          _invalid();
        }
      }
      if (atomExpansion > expansion) expansion = atomExpansion;
    }
    if (grouped) {
      if (position >= pattern.length || pattern[position] != ')') _invalid();
      position++;
    }
    return expansion;
  }

  _RegexAtom _atom() {
    final character = pattern[position++];
    if (character == '(') {
      if (++depth > 16) _invalid();
      if (position < pattern.length && pattern[position] == '?') {
        position++;
        if (position < pattern.length && pattern[position] == ':') {
          position++;
        } else {
          var flag = false;
          var minus = false;
          var afterMinus = false;
          while (position < pattern.length &&
              'imsU-'.contains(pattern[position])) {
            if (pattern[position++] == '-') {
              if (minus) _invalid();
              minus = true;
            } else {
              flag = true;
              if (minus) afterMinus = true;
            }
          }
          if (!flag || (minus && !afterMinus) || position >= pattern.length) {
            _invalid();
          }
          if (pattern[position] == ')') {
            position++;
            depth--;
            return const _RegexAtom(false, 0);
          }
          if (pattern[position++] != ':') _invalid();
        }
      }
      final expansion = _expression(grouped: true);
      depth--;
      return _RegexAtom(true, expansion);
    }
    if (character == '[') {
      _characterClass();
      return const _RegexAtom(true, 1);
    }
    if (character == r'\') {
      if (position >= pattern.length) _invalid();
      final kind = pattern[position];
      _escape(inClass: false);
      return _RegexAtom(!'bBAz'.contains(kind), 1);
    }
    if (character == '^' || character == r'$') {
      return const _RegexAtom(false, 1);
    }
    if ('*+?{}'.contains(character) || character == ')') _invalid();
    return const _RegexAtom(true, 1);
  }

  void _characterClass() {
    if (position < pattern.length && pattern[position] == '^') position++;
    var any = false;
    while (position < pattern.length) {
      if (pattern[position] == ']' && any) {
        position++;
        return;
      }
      final start = _classAtom();
      any = true;
      if (position + 1 < pattern.length &&
          pattern[position] == '-' &&
          pattern[position + 1] != ']') {
        position++;
        if (start == null) _invalid();
        final end = _classAtom();
        if (end == null || start > end) _invalid();
      }
    }
    _invalid();
  }

  int? _classAtom() {
    if (position >= pattern.length) _invalid();
    final character = pattern[position++];
    if (character == r'\') return _escape(inClass: true);
    if (character == '[' &&
        position < pattern.length &&
        pattern[position] == ':') {
      position++;
      final start = position;
      if (position < pattern.length && pattern[position] == '^') position++;
      while (position < pattern.length &&
          pattern.codeUnitAt(position) >= 0x61 &&
          pattern.codeUnitAt(position) <= 0x7a) {
        position++;
      }
      final raw = pattern.substring(start, position);
      final name = raw.startsWith('^') ? raw.substring(1) : raw;
      if (!const {
            'alnum',
            'alpha',
            'ascii',
            'blank',
            'cntrl',
            'digit',
            'graph',
            'lower',
            'print',
            'punct',
            'space',
            'upper',
            'word',
            'xdigit',
          }.contains(name) ||
          position + 1 >= pattern.length ||
          pattern[position] != ':' ||
          pattern[position + 1] != ']') {
        _invalid();
      }
      position += 2;
      return null;
    }
    return character.codeUnitAt(0);
  }

  int? _escape({required bool inClass}) {
    if (position >= pattern.length) _invalid();
    final character = pattern[position++];
    final unit = character.codeUnitAt(0);
    if (unit >= 0x30 && unit <= 0x39) _invalid();
    if (character == 'x') {
      final braces = position < pattern.length && pattern[position] == '{';
      if (braces) position++;
      var value = 0;
      var read = 0;
      while (position < pattern.length && (braces || read < 2)) {
        final digit = _hex(pattern.codeUnitAt(position));
        if (digit == null) break;
        position++;
        value = value * 16 + digit;
        if (++read > 6) _invalid();
      }
      if (braces) {
        if (read < 1 ||
            position >= pattern.length ||
            pattern[position++] != '}') {
          _invalid();
        }
      } else if (read != 2) {
        _invalid();
      }
      if (value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) {
        _invalid();
      }
      return value;
    }
    if ('dDsSwW'.contains(character)) return null;
    if ('bBAz'.contains(character)) {
      if (inClass) _invalid();
      return null;
    }
    if ('afnrtv'.contains(character)) {
      return switch (character) {
        'a' => 7,
        'f' => 12,
        'n' => 10,
        'r' => 13,
        't' => 9,
        _ => 11,
      };
    }
    if (unit >= 32 && unit <= 126 && !_alphaNumeric(unit)) return unit;
    // Unicode properties, quoting and engine-specific escapes are excluded.
    _invalid();
  }

  static bool _quantifier(String character) => '*+?{'.contains(character);

  _RegexRepeat _repeat() {
    if (pattern[position++] != '{') return const _RegexRepeat(1);
    final minimum = _count();
    var maximum = minimum;
    var unbounded = false;
    if (position < pattern.length && pattern[position] == ',') {
      position++;
      unbounded = position < pattern.length && pattern[position] == '}';
      maximum = unbounded ? 1000 : _count();
    }
    if (position >= pattern.length ||
        pattern[position++] != '}' ||
        minimum > maximum) {
      _invalid();
    }
    final count = unbounded ? minimum : maximum;
    return _RegexRepeat(
      count < 1 ? 1 : count,
      empty: !unbounded && maximum == 0,
    );
  }

  int _count() {
    var count = 0;
    final start = position;
    while (position < pattern.length &&
        pattern.codeUnitAt(position) >= 0x30 &&
        pattern.codeUnitAt(position) <= 0x39) {
      count = count * 10 + pattern.codeUnitAt(position++) - 0x30;
      if (count > 1000 || position - start > 4) _invalid();
    }
    if (position == start || (position - start > 1 && pattern[start] == '0')) {
      _invalid();
    }
    return count;
  }

  static int? _hex(int unit) {
    if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
    if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
    if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
    return null;
  }
}
