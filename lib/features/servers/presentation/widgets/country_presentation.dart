import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

/// Display-only country information; the original profile name stays intact.
@immutable
class CountryPresentation {
  final String? countryCode;
  final String displayName;

  const CountryPresentation._({
    required this.countryCode,
    required this.displayName,
  });

  /// Recognizes flag emoji or an explicit uppercase ISO country prefix.
  ///
  /// A code must be a separate token (or enclosed in brackets), so ordinary
  /// names such as "Denmark" and "Finland" are never shortened. Lowercase
  /// words are deliberately left alone, including "in progress".
  factory CountryPresentation.fromName(
    String name, {
    String fallbackName = '',
  }) {
    final original = name.trim();
    final prefix = _countryPrefix(original);
    if (prefix == null) {
      return CountryPresentation._(
        countryCode: null,
        displayName: original.isNotEmpty ? original : fallbackName.trim(),
      );
    }

    var remainder = _afterPrefix(original, prefix.end);
    // Some providers include both an emoji and the same textual ISO prefix.
    // Strip only matching redundant markers, keeping conflicting ones visible.
    while (remainder.isNotEmpty) {
      final repeated = _countryPrefix(remainder);
      if (repeated == null || repeated.code != prefix.code) break;
      remainder = _afterPrefix(remainder, repeated.end);
    }
    return CountryPresentation._(
      countryCode: prefix.code,
      displayName: remainder.isNotEmpty ? remainder : fallbackName.trim(),
    );
  }

  bool get hasFlag => countryCode != null;

  /// The adjacent title supplies the accessible name without duplicate ISO
  /// letters or flag emoji being read by assistive technology.
  String get semanticsLabel => displayName;

  static final _textPrefix = RegExp(
    r'^(?:\[([A-Z]{2})\]|\(([A-Z]{2})\)|([A-Z]{2})(?=$|[\s_\-–—|:·•/\\,;]))',
  );
  static final _leadingSeparators = RegExp(r'^[\s_\-–—|:·•/\\,;\uFE0F]+');

  static ({String code, int end})? _countryPrefix(String name) {
    final runes = name.runes.take(2).toList();
    if (runes.length == 2 &&
        runes.every((rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF)) {
      final code = String.fromCharCodes(
        runes.map((rune) => rune - 0x1F1E6 + 65),
      );
      if (FlagCode.fromCountryCode(code) != null) {
        return (code: code, end: String.fromCharCodes(runes).length);
      }
      return null;
    }

    final match = _textPrefix.firstMatch(name);
    if (match == null) return null;
    final code = match.group(1) ?? match.group(2) ?? match.group(3)!;
    if (FlagCode.fromCountryCode(code) == null) return null;
    return (code: code, end: match.end);
  }

  static String _afterPrefix(String name, int end) =>
      name.substring(end).replaceFirst(_leadingSeparators, '').trim();
}

/// A bundled Noto Emoji flag, independent of platform emoji fonts.
///
/// Decorative next to a server title by default. Supply [semanticsLabel] only
/// when the icon itself needs an accessible description.
class CountryFlagIcon extends StatelessWidget {
  final CountryPresentation presentation;
  final double width;
  final double height;
  final String? semanticsLabel;

  const CountryFlagIcon({
    super.key,
    required this.presentation,
    this.width = 24,
    this.height = 20,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final code = presentation.countryCode;
    final visual = ExcludeSemantics(
      child: code != null
          ? Image.asset(
              'assets/flags/noto/${code.toLowerCase()}.png',
              height: height,
              width: width,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, _, _) => Icon(
                Icons.public_rounded,
                size: height,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : SizedBox(
              width: width,
              height: height,
              child: Icon(
                Icons.public_rounded,
                size: height,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
    );
    final label = semanticsLabel?.trim();
    return label == null || label.isEmpty
        ? visual
        : Semantics(image: true, label: label, child: visual);
  }
}
