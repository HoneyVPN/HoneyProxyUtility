import 'package:flutter_test/flutter_test.dart';

import 'package:honeyproxyutility/features/servers/presentation/widgets/country_presentation.dart';

void main() {
  group('CountryPresentation', () {
    final examples = <String, (String, String)>{
      '🇩🇪 Germany': ('DE', 'Germany'),
      ' 🇳🇱 Netherlands 1 ': ('NL', 'Netherlands 1'),
      '🇫🇮Finland': ('FI', 'Finland'),
      '🇩🇪\uFE0F — Germany': ('DE', 'Germany'),
      'DE Germany': ('DE', 'Germany'),
      'NL Netherlands 2': ('NL', 'Netherlands 2'),
      'FI Finland': ('FI', 'Finland'),
      'DE-Germany': ('DE', 'Germany'),
      'NL | Netherlands': ('NL', 'Netherlands'),
      'FI: Finland': ('FI', 'Finland'),
      'DE_ • Germany': ('DE', 'Germany'),
      '[DE] Germany': ('DE', 'Germany'),
      '(NL) Netherlands': ('NL', 'Netherlands'),
      '🇩🇪 DE Germany': ('DE', 'Germany'),
      'DE 🇩🇪 Germany': ('DE', 'Germany'),
      'NL\u00A0Netherlands': ('NL', 'Netherlands'),
    };
    for (final entry in examples.entries) {
      test('renders country and clean title for ${entry.key}', () {
        final view = CountryPresentation.fromName(entry.key);
        expect(view.countryCode, entry.value.$1);
        expect(view.displayName, entry.value.$2);
        expect(view.semanticsLabel, entry.value.$2);
      });
    }

    test('does not guess countries from ordinary words or unknown codes', () {
      for (final name in [
        'Denmark',
        'Finland',
        'DEGermany',
        'NL2 Netherlands',
        'in progress',
        'de Germany',
        'Random server',
        'ZZ Server',
        '🇿🇿 Server',
        '🇩 Server',
      ]) {
        final view = CountryPresentation.fromName(name);
        expect(view.countryCode, isNull, reason: name);
        expect(view.displayName, name, reason: name);
      }
    });

    test('a conflicting country marker is preserved rather than hidden', () {
      final view = CountryPresentation.fromName('🇩🇪 NL Netherlands');
      expect(view.countryCode, 'DE');
      expect(view.displayName, 'NL Netherlands');
    });

    test('empty and country-only names use the host fallback', () {
      for (final name in ['', '  ', 'DE', '🇩🇪', '[DE]', 'DE — ']) {
        final view = CountryPresentation.fromName(
          name,
          fallbackName: ' server.example ',
        );
        expect(view.displayName, 'server.example', reason: name);
        expect(view.semanticsLabel, 'server.example', reason: name);
      }
      expect(CountryPresentation.fromName('DE').displayName, isEmpty);
    });
  });
}
