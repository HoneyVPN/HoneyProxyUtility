import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoTextThemeData;
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;

/// Shared Honey tokens. Status colors remain distinct from the brand accent.
class NexPalette {
  static const darkBg = Color(0xFF17171A);
  static const darkSurface = Color(0xFF232326);
  static const darkSurface2 = Color(0xFF2C2C30);
  static const darkOutline = Color(0xFF45454D);
  static const darkOnSurface = Color(0xFFF5F5F7);
  static const darkSubtext = Color(0xFFACACB4);

  static const lightBg = Color(0xFFF5F5F7);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurface2 = Color(0xFFEEEEF2);
  static const lightOutline = Color(0xFFD1D1D8);
  static const lightOnSurface = Color(0xFF1D1D1F);
  static const lightSubtext = Color(0xFF63636B);

  static const accent = Color(0xFFC8A96E);
  static const accentDark = Color(0xFF8B611B);
}

class NexColors {
  static const connected = Color(0xFF4CAF81);
  static const connecting = Color(0xFFD4A84B);
  static const disconnected = NexPalette.accent;
  static const error = Color(0xFFCF6679);

  static Color warningFor(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFFF2C14D)
      : const Color(0xFF896500);

  static const platinum = Color(0xFF9B8EC4);
  static const gold = NexPalette.accent;
  static const vmess = Color(0xFF6B9FD4);
  static const vless = Color(0xFF5BB8C4);
  static const trojan = Color(0xFF9B8EC4);
  static const shadowsocks = Color(0xFFD47BA0);
  static const hysteria2 = Color(0xFFCF6679);
  static const tuic = Color(0xFFD4915A);
  static const wireguard = Color(0xFF4CAF81);
  static const amneziaWG = Color(0xFF5B9BD5);
  static const naive = Color(0xFF8BB56A);
}

final honeyThemeLight = _honeyTheme(Brightness.light);
final honeyThemeDark = _honeyTheme(Brightness.dark);

ThemeData _honeyTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  // CupertinoSystemText is Flutter's supported alias for the native Apple
  // system font. No SF font files are bundled or assumed on web/other hosts.
  final nativeApple =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.iOS);
  final fontFamily = nativeApple
      ? const CupertinoTextThemeData().textStyle.fontFamily
      : 'Inter';
  final background = dark ? NexPalette.darkBg : NexPalette.lightBg;
  final surface = dark ? NexPalette.darkSurface : NexPalette.lightSurface;
  final elevated = dark ? NexPalette.darkSurface2 : NexPalette.lightSurface2;
  final text = dark ? NexPalette.darkOnSurface : NexPalette.lightOnSurface;
  final muted = dark ? NexPalette.darkSubtext : NexPalette.lightSubtext;
  final primary = dark ? NexPalette.accent : NexPalette.accentDark;
  final outline = dark ? NexPalette.darkOutline : NexPalette.lightOutline;
  final cs = ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: dark ? NexPalette.darkBg : Colors.white,
    primaryContainer: dark ? const Color(0xFF3F3320) : const Color(0xFFF2E1BB),
    onPrimaryContainer: dark
        ? const Color(0xFFFFE0A0)
        : const Color(0xFF4E350B),
    secondary: muted,
    onSecondary: surface,
    secondaryContainer: elevated,
    onSecondaryContainer: text,
    tertiary: dark ? NexColors.connected : const Color(0xFF246848),
    onTertiary: dark ? NexPalette.darkBg : Colors.white,
    tertiaryContainer: dark ? const Color(0xFF203B30) : const Color(0xFFD9EDDF),
    onTertiaryContainer: dark
        ? const Color(0xFFB8EAD0)
        : const Color(0xFF17442D),
    error: dark ? const Color(0xFFE68492) : const Color(0xFFB52E45),
    onError: dark ? NexPalette.darkBg : Colors.white,
    errorContainer: dark ? const Color(0xFF43252C) : const Color(0xFFFFE1E5),
    onErrorContainer: dark ? const Color(0xFFFFCFD6) : const Color(0xFF671728),
    surface: surface,
    onSurface: text,
    onSurfaceVariant: muted,
    outline: outline,
    outlineVariant: dark ? const Color(0xFF37373E) : const Color(0xFFDCDCE2),
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: dark ? NexPalette.lightSurface : NexPalette.darkSurface,
    onInverseSurface: dark
        ? NexPalette.lightOnSurface
        : NexPalette.darkOnSurface,
    inversePrimary: dark ? NexPalette.accentDark : NexPalette.accent,
    surfaceContainerLowest: dark ? const Color(0xFF121214) : Colors.white,
    surfaceContainerLow: surface,
    surfaceContainer: elevated,
    surfaceContainerHigh: dark
        ? const Color(0xFF333338)
        : const Color(0xFFE8E8ED),
    surfaceContainerHighest: dark
        ? const Color(0xFF3C3C42)
        : const Color(0xFFDDDDE3),
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: cs,
    fontFamily: fontFamily,
  );
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(8),
  );

  return base.copyWith(
    scaffoldBackgroundColor: background,
    textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      color: surface,
      margin: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: 0.14),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: background,
      foregroundColor: text,
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontWeight: FontWeight.w600,
        fontSize: 20,
        letterSpacing: -0.3,
        color: text,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: buttonShape,
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        side: BorderSide(color: outline.withValues(alpha: 0.4), width: 0.5),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: buttonShape,
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: BorderSide.none,
      backgroundColor: elevated,
      selectedColor: cs.primaryContainer,
      labelStyle: TextStyle(fontFamily: fontFamily, fontSize: 12, color: text),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: outline.withValues(alpha: 0.35),
          width: 0.5,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      hintStyle: TextStyle(color: muted),
    ),
    dividerTheme: DividerThemeData(
      color: cs.outlineVariant,
      thickness: 0.5,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontWeight: FontWeight.w500,
        fontSize: 15,
        color: text,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 13,
        color: muted,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: elevated,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? primary : muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: fontFamily,
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? text : muted,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? elevated : NexPalette.lightOnSurface,
      contentTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        color: NexPalette.darkOnSurface,
      ),
      actionTextColor: NexPalette.accent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}

/// Pointer layouts can use dense controls; touch layouts retain generous targets.
/// Apply above the Navigator so dialogs and every feature share the same scale.
ThemeData honeyThemeForWidth(ThemeData theme, double width) {
  final compact = width >= 700;
  final extent = compact ? 34.0 : 44.0;
  final cs = theme.colorScheme;
  final density = compact ? VisualDensity.compact : VisualDensity.standard;
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  final labelStyle = theme.textTheme.labelLarge?.copyWith(
    fontSize: compact ? 12 : 14,
    fontWeight: FontWeight.w500,
  );
  final targetSize = compact
      ? MaterialTapTargetSize.shrinkWrap
      : MaterialTapTargetSize.padded;
  return theme.copyWith(
    visualDensity: density,
    materialTapTargetSize: targetSize,
    appBarTheme: theme.appBarTheme.copyWith(
      toolbarHeight: compact ? 44 : 52,
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
        fontSize: compact ? 16 : 18,
        letterSpacing: 0,
      ),
    ),
    textTheme: theme.textTheme.copyWith(
      bodyLarge: theme.textTheme.bodyLarge?.copyWith(
        fontSize: compact ? 13 : 15,
      ),
      bodyMedium: theme.textTheme.bodyMedium?.copyWith(
        fontSize: compact ? 13 : 14,
      ),
      titleMedium: theme.textTheme.titleMedium?.copyWith(
        fontSize: compact ? 14 : 16,
      ),
      titleLarge: theme.textTheme.titleLarge?.copyWith(
        fontSize: compact ? 16 : 18,
      ),
      labelLarge: labelStyle,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: Size.square(extent),
        padding: EdgeInsets.all(compact ? 6 : 10),
        tapTargetSize: targetSize,
        visualDensity: VisualDensity.standard,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: Size(0, extent),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 18,
          vertical: compact ? 7 : 10,
        ),
        textStyle: labelStyle,
        shape: shape,
        tapTargetSize: targetSize,
        visualDensity: VisualDensity.standard,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: Size(0, extent),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 18,
          vertical: compact ? 7 : 10,
        ),
        textStyle: labelStyle,
        shape: shape,
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
        tapTargetSize: targetSize,
        visualDensity: VisualDensity.standard,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: Size(0, extent),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 7 : 10,
        ),
        textStyle: labelStyle,
        shape: shape,
        tapTargetSize: targetSize,
        visualDensity: VisualDensity.standard,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(0, extent)),
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14,
            vertical: compact ? 7 : 10,
          ),
        ),
        side: const WidgetStatePropertyAll(BorderSide.none),
        shape: WidgetStatePropertyAll(shape),
        textStyle: WidgetStatePropertyAll(labelStyle),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? cs.surfaceContainer
              : Colors.transparent,
        ),
        foregroundColor: WidgetStatePropertyAll(cs.onSurface),
        visualDensity: VisualDensity.standard,
        tapTargetSize: targetSize,
      ),
    ),
    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
      isDense: compact,
      contentPadding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: compact ? 10 : 14,
      ),
    ),
    popupMenuTheme: theme.popupMenuTheme.copyWith(
      color: cs.surface,
      surfaceTintColor: Colors.transparent,
      shape: shape,
      textStyle: theme.textTheme.bodyMedium?.copyWith(
        fontSize: compact ? 13 : 14,
      ),
    ),
  );
}
