import 'package:flutter/material.dart';

// ─── Palette ────────────────────────────────────────────────────────────────

class NexPalette {
  // Dark — velvety matte charcoal
  static const darkBg        = Color(0xFF16161A);  // deepest charcoal
  static const darkSurface   = Color(0xFF1E1E24);  // card surface
  static const darkSurface2  = Color(0xFF26262E);  // elevated elements
  static const darkOutline   = Color(0xFF36363F);  // subtle borders
  static const darkOnSurface = Color(0xFFE8E4DC);  // warm white text
  static const darkSubtext   = Color(0xFF8A8694);  // muted text

  // Light — milky cream / warm beige
  static const lightBg        = Color(0xFFF7F3EC);  // warm cream background
  static const lightSurface   = Color(0xFFFDF9F3);  // milky white card
  static const lightSurface2  = Color(0xFFEDE8DF);  // slightly deeper beige
  static const lightOutline   = Color(0xFFD6CEBD);  // warm gray border
  static const lightOnSurface = Color(0xFF2A2219);  // dark warm brown text
  static const lightSubtext   = Color(0xFF8C7F6A);  // warm gray-brown muted

  // Accent — warm gold (works on both themes)
  static const accent     = Color(0xFFC8A96E);  // warm gold
  static const accentDark = Color(0xFFB8935A);  // deeper gold for light theme
}

// ─── Protocol & Status tokens ───────────────────────────────────────────────

class NexColors {
  static const connected    = Color(0xFF4CAF81);  // soft sage green
  static const connecting   = Color(0xFFD4A84B);  // muted amber
  static const disconnected = NexPalette.accent;
  static const error        = Color(0xFFCF6679);  // muted rose

  static const platinum = Color(0xFF9B8EC4);  // soft violet
  static const gold     = NexPalette.accent;

  static const vmess       = Color(0xFF6B9FD4);  // soft blue
  static const vless       = Color(0xFF5BB8C4);  // soft teal
  static const trojan      = Color(0xFF9B8EC4);  // soft violet
  static const shadowsocks = Color(0xFFD47BA0);  // soft pink
  static const hysteria2   = Color(0xFFCF6679);  // muted rose
  static const tuic        = Color(0xFFD4915A);  // warm orange
  static const wireguard   = Color(0xFF4CAF81);  // sage green
  static const naive       = Color(0xFF8BB56A);  // olive green
}

// ─── Light theme ────────────────────────────────────────────────────────────

final honeyThemeLight = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme(
    brightness: Brightness.light,
    primary:          NexPalette.accentDark,
    onPrimary:        Colors.white,
    primaryContainer: const Color(0xFFEEDDBF),
    onPrimaryContainer: NexPalette.lightOnSurface,
    secondary:        const Color(0xFF8C7F6A),
    onSecondary:      Colors.white,
    secondaryContainer: NexPalette.lightSurface2,
    onSecondaryContainer: NexPalette.lightOnSurface,
    tertiary:         NexColors.connected,
    onTertiary:       Colors.white,
    tertiaryContainer: const Color(0xFFD1ECD9),
    onTertiaryContainer: const Color(0xFF1A3D28),
    error:            NexColors.error,
    onError:          Colors.white,
    errorContainer:   const Color(0xFFFFDAD6),
    onErrorContainer: const Color(0xFF410002),
    surface:          NexPalette.lightSurface,
    onSurface:        NexPalette.lightOnSurface,
    onSurfaceVariant: NexPalette.lightSubtext,
    outline:          NexPalette.lightOutline,
    outlineVariant:   const Color(0xFFE5DED3),
    shadow:           Colors.black,
    scrim:            Colors.black,
    inverseSurface:   NexPalette.darkSurface,
    onInverseSurface: NexPalette.darkOnSurface,
    inversePrimary:   NexPalette.accent,
    surfaceContainerLowest:  const Color(0xFFFFFDF9),
    surfaceContainerLow:     NexPalette.lightSurface,
    surfaceContainer:        NexPalette.lightSurface2,
    surfaceContainerHigh:    const Color(0xFFE5DED3),
    surfaceContainerHighest: NexPalette.lightOutline,
  ),
  fontFamily: 'Inter',
  scaffoldBackgroundColor: NexPalette.lightBg,
  cardTheme: CardThemeData(
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    color: NexPalette.lightSurface,
    margin: EdgeInsets.zero,
  ),
  appBarTheme: const AppBarTheme(
    centerTitle: false,
    elevation: 0,
    scrolledUnderElevation: 0,
    backgroundColor: NexPalette.lightBg,
    foregroundColor: NexPalette.lightOnSurface,
    titleTextStyle: TextStyle(
      fontFamily: 'Inter',
      fontWeight: FontWeight.w600,
      fontSize: 20,
      color: NexPalette.lightOnSurface,
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: NexPalette.accentDark,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 15),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: NexPalette.accentDark,
      side: const BorderSide(color: NexPalette.lightOutline),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w500, fontSize: 15),
    ),
  ),
  chipTheme: ChipThemeData(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    side: const BorderSide(color: NexPalette.lightOutline),
    backgroundColor: NexPalette.lightSurface,
    selectedColor: const Color(0xFFEEDDBF),
    labelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 13),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: NexPalette.lightSurface2,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: NexPalette.lightOutline, width: 1),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: NexPalette.accentDark, width: 1.5),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    hintStyle: const TextStyle(color: NexPalette.lightSubtext),
  ),
  dividerTheme: const DividerThemeData(
    color: NexPalette.lightOutline,
    thickness: 1,
    space: 1,
  ),
  listTileTheme: const ListTileThemeData(
    titleTextStyle: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w500, fontSize: 15, color: NexPalette.lightOnSurface),
    subtitleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 13, color: NexPalette.lightSubtext),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: NexPalette.lightSurface,
    indicatorColor: const Color(0xFFEEDDBF),
    labelTextStyle: WidgetStateProperty.all(
      const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.w500),
    ),
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: NexPalette.lightOnSurface,
    contentTextStyle: const TextStyle(
      fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w500,
      color: NexPalette.lightSurface,
    ),
    actionTextColor: NexPalette.accentDark,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
);

// ─── Dark theme ─────────────────────────────────────────────────────────────

final honeyThemeDark = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme(
    brightness: Brightness.dark,
    primary:          NexPalette.accent,
    onPrimary:        NexPalette.darkBg,
    primaryContainer: const Color(0xFF3A2E1A),
    onPrimaryContainer: const Color(0xFFEDD9B0),
    secondary:        NexPalette.darkSubtext,
    onSecondary:      NexPalette.darkOnSurface,
    secondaryContainer: NexPalette.darkSurface2,
    onSecondaryContainer: NexPalette.darkOnSurface,
    tertiary:         NexColors.connected,
    onTertiary:       NexPalette.darkBg,
    tertiaryContainer: const Color(0xFF1A3228),
    onTertiaryContainer: const Color(0xFFB0D9C0),
    error:            NexColors.error,
    onError:          NexPalette.darkBg,
    errorContainer:   const Color(0xFF3D1820),
    onErrorContainer: const Color(0xFFE8B0B8),
    surface:          NexPalette.darkSurface,
    onSurface:        NexPalette.darkOnSurface,
    onSurfaceVariant: NexPalette.darkSubtext,
    outline:          NexPalette.darkOutline,
    outlineVariant:   const Color(0xFF2C2C35),
    shadow:           Colors.black,
    scrim:            Colors.black,
    inverseSurface:   NexPalette.lightSurface,
    onInverseSurface: NexPalette.lightOnSurface,
    inversePrimary:   NexPalette.accentDark,
    surfaceContainerLowest:  const Color(0xFF111115),
    surfaceContainerLow:     NexPalette.darkSurface,
    surfaceContainer:        NexPalette.darkSurface2,
    surfaceContainerHigh:    const Color(0xFF2E2E38),
    surfaceContainerHighest: NexPalette.darkOutline,
  ),
  fontFamily: 'Inter',
  scaffoldBackgroundColor: NexPalette.darkBg,
  cardTheme: CardThemeData(
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    color: NexPalette.darkSurface,
    margin: EdgeInsets.zero,
  ),
  appBarTheme: const AppBarTheme(
    centerTitle: false,
    elevation: 0,
    scrolledUnderElevation: 0,
    backgroundColor: NexPalette.darkBg,
    foregroundColor: NexPalette.darkOnSurface,
    titleTextStyle: TextStyle(
      fontFamily: 'Inter',
      fontWeight: FontWeight.w600,
      fontSize: 20,
      color: NexPalette.darkOnSurface,
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: NexPalette.accent,
      foregroundColor: NexPalette.darkBg,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 15),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: NexPalette.accent,
      side: const BorderSide(color: NexPalette.darkOutline),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w500, fontSize: 15),
    ),
  ),
  chipTheme: ChipThemeData(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    side: const BorderSide(color: NexPalette.darkOutline),
    backgroundColor: NexPalette.darkSurface2,
    selectedColor: const Color(0xFF3A2E1A),
    labelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 13, color: NexPalette.darkOnSurface),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: NexPalette.darkSurface2,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: NexPalette.darkOutline, width: 1),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: NexPalette.accent, width: 1.5),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    hintStyle: const TextStyle(color: NexPalette.darkSubtext),
  ),
  dividerTheme: const DividerThemeData(
    color: NexPalette.darkOutline,
    thickness: 1,
    space: 1,
  ),
  listTileTheme: const ListTileThemeData(
    titleTextStyle: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w500, fontSize: 15, color: NexPalette.darkOnSurface),
    subtitleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 13, color: NexPalette.darkSubtext),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: NexPalette.darkSurface,
    indicatorColor: const Color(0xFF3A2E1A),
    labelTextStyle: WidgetStateProperty.all(
      const TextStyle(fontFamily: 'Inter', fontSize: 12, fontWeight: FontWeight.w500, color: NexPalette.darkOnSurface),
    ),
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: NexPalette.darkSurface2,
    contentTextStyle: const TextStyle(
      fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w500,
      color: NexPalette.darkOnSurface,
    ),
    actionTextColor: NexPalette.accent,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
);
