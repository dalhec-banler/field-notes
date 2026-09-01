import 'package:flutter/material.dart';

import 'tokens.dart';

/// The app theme, built from the active [skin] (D-023).
///
/// Under press this is the Field Station rulebook (README §2): two paper
/// tones and ink, 1.5 px ink borders, radius 0 everywhere except pills and
/// circles, hard offset shadows only. Under quiet the same slots resolve to
/// system type, soft radii and hairline borders. The colour and font values
/// arrive through the token getters automatically; only shape and label
/// typography branch here.
ThemeData appTheme() {
  final radius = BorderRadius.circular(skin.radiusControl);
  final upper = skin.upperLabels;
  // Press buttons speak uppercase letterspaced mono at 10.5; with a system
  // face that reads as shouting in a doll's font, so quiet uses its own
  // label voice.
  final buttonLabel = upper
      ? TextStyle(
          fontFamily: Type.mono,
          fontWeight: FontWeight.w500,
          fontSize: 10.5,
          letterSpacing: 1.6,
        )
      : const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          letterSpacing: 0.1,
        );
  final scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Press.ink,
    onPrimary: Press.paper,
    secondary: Press.oxblood,
    onSecondary: Press.paper,
    error: Press.oxblood,
    onError: Press.paper,
    surface: Press.paper,
    onSurface: Press.ink,
  );

  final inkBorder = BorderSide(color: Press.borderInk, width: skin.borderCard);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Press.paper,
    fontFamily: Type.serif,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Press.paperRaised,
    dividerTheme: DividerThemeData(color: Press.divider, thickness: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: Press.paper,
      foregroundColor: Press.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Press.ink,
        foregroundColor: Press.paper,
        shape: RoundedRectangleBorder(borderRadius: radius),
        minimumSize: const Size(Metrics.touchMin, Metrics.touchMin),
        textStyle: upper
            ? TextStyle(
                fontFamily: Type.slab,
                fontWeight: FontWeight.w900,
                fontSize: 15,
                letterSpacing: 0.6,
              )
            : const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15.5,
                letterSpacing: 0.1,
              ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Press.ink,
        side: skin.upperLabels
            ? inkBorder
            : BorderSide(color: Press.inkSoft.withValues(alpha: 0.4)),
        shape: RoundedRectangleBorder(borderRadius: radius),
        minimumSize: const Size(Metrics.touchMin, Metrics.touchMin),
        textStyle: buttonLabel,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Press.ink,
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: buttonLabel,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Press.paperRaised,
      border: OutlineInputBorder(borderSide: inkBorder, borderRadius: radius),
      enabledBorder: OutlineInputBorder(
        borderSide: inkBorder,
        borderRadius: radius,
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Press.oxblood, width: 1.5),
        borderRadius: radius,
      ),
      labelStyle: upper
          ? TextStyle(
              fontFamily: Type.mono,
              fontSize: 11,
              letterSpacing: 1.4,
              color: Press.inkSoft,
            )
          : TextStyle(fontSize: 14, color: Press.inkSoft),
      hintStyle: upper
          ? TextStyle(
              fontFamily: Type.mono,
              fontSize: 11,
              color: const Color(0x8C2C2620),
            )
          : TextStyle(
              fontSize: 14,
              color: Press.inkSoft.withValues(alpha: 0.55),
            ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Press.paper,
      shape: RoundedRectangleBorder(
        side: skin.upperLabels ? inkBorder : BorderSide.none,
        borderRadius: BorderRadius.circular(skin.radiusCard),
      ),
      titleTextStyle: TextStyle(
        fontFamily: Type.slab,
        fontWeight: FontWeight.w700,
        fontSize: 18,
        color: Press.ink,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: Press.paper,
      shape: skin.upperLabels
          ? Border(
              top: BorderSide(
                color: Press.ink,
                width: Metrics.borderStructural,
              ),
            )
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(skin.radiusCard + 4),
              ),
            ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Press.ink,
      contentTextStyle: upper
          ? TextStyle(
              fontFamily: Type.mono,
              fontSize: 10,
              letterSpacing: 1.2,
              color: Press.paper,
            )
          : TextStyle(fontSize: 13.5, color: Press.paper),
      actionTextColor: Press.gold,
      shape: RoundedRectangleBorder(borderRadius: radius),
      behavior: SnackBarBehavior.floating,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Press.paper,
      side: skin.borderCard > 0
          ? BorderSide(color: Press.borderInk, width: 1)
          : BorderSide(color: Press.paperEdge, width: 1),
      shape: const StadiumBorder(),
      labelStyle: upper
          ? TextStyle(
              fontFamily: Type.mono,
              fontSize: 9.5,
              letterSpacing: 1.5,
              color: Press.ink,
            )
          : TextStyle(fontSize: 12.5, color: Press.ink),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
    ),
    listTileTheme: ListTileThemeData(
      minTileHeight: Metrics.touchMin,
      iconColor: Press.ink,
    ),
    materialTapTargetSize: MaterialTapTargetSize.padded,
    textTheme: TextTheme(
      // Screen titles: Zilla Slab 900 30 uppercase (applied at call sites).
      headlineLarge: TextStyle(
        fontFamily: Type.slab,
        fontWeight: FontWeight.w900,
        fontSize: 30,
        height: 0.9,
        color: Press.ink,
      ),
      titleLarge: TextStyle(
        fontFamily: Type.slab,
        fontWeight: FontWeight.w700,
        fontSize: 18,
        color: Press.ink,
      ),
      titleMedium: TextStyle(
        fontFamily: Type.slab,
        fontWeight: FontWeight.w700,
        fontSize: 16,
        color: Press.ink,
      ),
      bodyLarge: TextStyle(
        fontFamily: Type.serif,
        fontSize: 16.5,
        height: 1.5,
        color: Press.ink,
      ),
      bodyMedium: TextStyle(
        fontFamily: Type.serif,
        fontSize: 15,
        height: 1.5,
        color: Press.ink,
      ),
      bodySmall: upper
          ? TextStyle(
              fontFamily: Type.mono,
              fontSize: 9.5,
              letterSpacing: 1.0,
              color: Press.inkSoft,
            )
          : TextStyle(fontSize: 12, color: Press.inkSoft),
      labelLarge: upper
          ? TextStyle(
              fontFamily: Type.mono,
              fontWeight: FontWeight.w500,
              fontSize: 11,
              letterSpacing: 1.6,
              color: Press.ink,
            )
          : TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: Press.ink,
            ),
    ),
  );
}

/// The historical name; screens and the desktop shell still call this.
ThemeData fieldStationTheme() => appTheme();
