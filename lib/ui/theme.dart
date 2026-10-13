import 'package:flutter/material.dart';

import '../engine/engine.dart';

/// Ink and menthol: deep blue-black surfaces with a cool mint accent.
abstract final class Palette {
  static const ink = Color(0xFF0C101B);
  static const inkRaised = Color(0xFF121827);
  static const inkPanel = Color(0xFF182033);
  static const inkHigh = Color(0xFF1F2A42);
  static const inkLine = Color(0xFF2A3652);
  static const mint = Color(0xFF7FE6C6);
  static const mintDeep = Color(0xFF12956F);
  static const paper = Color(0xFFF1F9F6);
}

const _dark = ColorScheme(
  brightness: Brightness.dark,
  primary: Palette.mint,
  onPrimary: Color(0xFF05241A),
  primaryContainer: Color(0xFF173A35),
  onPrimaryContainer: Color(0xFFB4F5E0),
  secondary: Color(0xFF9FB2D6),
  onSecondary: Palette.ink,
  tertiary: Color(0xFF9DB4FF),
  onTertiary: Palette.ink,
  error: Color(0xFFFF8C8C),
  onError: Color(0xFF3A0A0A),
  surface: Palette.ink,
  onSurface: Color(0xFFE7EDF6),
  onSurfaceVariant: Color(0xFF8997B0),
  outline: Color(0xFF55627D),
  outlineVariant: Palette.inkLine,
  surfaceContainerLowest: Color(0xFF080B13),
  surfaceContainerLow: Palette.inkRaised,
  surfaceContainer: Palette.inkPanel,
  surfaceContainerHigh: Palette.inkHigh,
  surfaceContainerHighest: Color(0xFF27334F),
  inverseSurface: Color(0xFFE7EDF6),
  onInverseSurface: Palette.ink,
);

const _light = ColorScheme(
  brightness: Brightness.light,
  primary: Palette.mintDeep,
  onPrimary: Colors.white,
  primaryContainer: Color(0xFFC9F3E5),
  onPrimaryContainer: Color(0xFF07382B),
  secondary: Color(0xFF3F4C66),
  onSecondary: Colors.white,
  tertiary: Color(0xFF4660C8),
  onTertiary: Colors.white,
  error: Color(0xFFC83838),
  onError: Colors.white,
  surface: Palette.paper,
  onSurface: Color(0xFF111827),
  onSurfaceVariant: Color(0xFF5B677D),
  outline: Color(0xFF8D99AD),
  outlineVariant: Color(0xFFD5E4DE),
  surfaceContainerLowest: Colors.white,
  surfaceContainerLow: Colors.white,
  surfaceContainer: Color(0xFFE6F3EE),
  surfaceContainerHigh: Colors.white,
  surfaceContainerHighest: Color(0xFFDCECE6),
  inverseSurface: Color(0xFF111827),
  onInverseSurface: Palette.paper,
);

ThemeData buildTheme(Brightness brightness) {
  final scheme = brightness == Brightness.dark ? _dark : _light;
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: NoSplash.splashFactory,
    dividerColor: scheme.outlineVariant,
    textTheme: base.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: scheme.onPrimaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      isDense: true,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainer,
      modalBarrierColor: Colors.black.withValues(alpha: 0.45),
      dragHandleColor: scheme.outline,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}

/// The colour that tells the state of a torrent at a glance: blue while it
/// downloads, mint once it is done, violet while it prepares, grey on pause
/// and red on an error.
Color stateColor(ColorScheme scheme, TorrentState state) {
  final dark = scheme.brightness == Brightness.dark;
  return switch (state) {
    TorrentState.downloading =>
      dark ? const Color(0xFF6FB1FF) : const Color(0xFF2468D8),
    TorrentState.seeding => scheme.primary,
    TorrentState.checking || TorrentState.metadata =>
      dark ? const Color(0xFFC3A6FF) : const Color(0xFF7448D0),
    TorrentState.paused => scheme.outline,
    TorrentState.error => scheme.error,
  };
}
