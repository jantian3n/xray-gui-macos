import 'dart:io';

import 'package:flutter/material.dart';

import 'features/home/presentation/home_page.dart';

class XrayGuiApp extends StatelessWidget {
  const XrayGuiApp({super.key});

  @override
  Widget build(BuildContext context) {
    final bool isMacOS = Platform.isMacOS;
    final ColorScheme seedScheme = ColorScheme.fromSeed(
      seedColor: isMacOS ? const Color(0xFF0A84FF) : const Color(0xFF006A64),
      brightness: Brightness.light,
    );
    final ColorScheme colorScheme = isMacOS
        ? seedScheme.copyWith(
            primary: const Color(0xFF0A84FF),
            onPrimary: Colors.white,
            secondary: const Color(0xFF64748B),
            tertiary: const Color(0xFF6B7C93),
            surface: const Color(0xFFF5F6F8),
            surfaceContainerLow: Colors.white,
            surfaceContainerHighest: const Color(0xFFEEF1F5),
            onSurface: const Color(0xFF111418),
            onSurfaceVariant: const Color(0xFF5F6672),
            outline: const Color(0xFFCBD3DC),
            outlineVariant: const Color(0xFFE1E6EC),
            error: const Color(0xFFD92D20),
          )
        : seedScheme;

    return MaterialApp(
      title: 'Xray GUI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        visualDensity: isMacOS ? VisualDensity.compact : VisualDensity.standard,
        scaffoldBackgroundColor:
            isMacOS ? const Color(0xFFF3F5F8) : colorScheme.surface,
        splashFactory: isMacOS ? NoSplash.splashFactory : null,
        highlightColor: Colors.transparent,
        hoverColor: isMacOS
            ? colorScheme.primary.withValues(alpha: 0.045)
            : colorScheme.primary.withValues(alpha: 0.08),
        appBarTheme: AppBarTheme(
          elevation: 0,
          centerTitle: false,
          backgroundColor: Colors.transparent,
          foregroundColor: colorScheme.onSurface,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: isMacOS
              ? Colors.white.withValues(alpha: 0.88)
              : colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(isMacOS ? 18 : 28),
            side: isMacOS
                ? BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.92),
                  )
                : BorderSide.none,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: isMacOS
              ? Colors.white.withValues(alpha: 0.94)
              : colorScheme.surfaceContainerHighest,
          labelStyle: TextStyle(
            color: colorScheme.onSurfaceVariant,
          ),
          hintStyle: TextStyle(
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.82),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(isMacOS ? 12 : 20),
            borderSide: BorderSide(
              color: isMacOS
                  ? colorScheme.outline.withValues(alpha: 0.9)
                  : Colors.transparent,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(isMacOS ? 12 : 20),
            borderSide: BorderSide(
              color: isMacOS
                  ? colorScheme.outline.withValues(alpha: 0.9)
                  : Colors.transparent,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(isMacOS ? 12 : 20),
            borderSide: BorderSide(
              color: colorScheme.primary,
              width: isMacOS ? 1.2 : 1,
            ),
          ),
          contentPadding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: isMacOS ? 12 : 16,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: Size(0, isMacOS ? 38 : 44),
            padding: EdgeInsets.symmetric(
              horizontal: isMacOS ? 16 : 20,
              vertical: isMacOS ? 0 : 8,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(isMacOS ? 12 : 18),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: Size(0, isMacOS ? 38 : 44),
            padding: EdgeInsets.symmetric(
              horizontal: isMacOS ? 16 : 20,
              vertical: isMacOS ? 0 : 8,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(isMacOS ? 12 : 18),
            ),
            side: BorderSide(
              color: isMacOS
                  ? colorScheme.outline.withValues(alpha: 0.95)
                  : colorScheme.outlineVariant,
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: Size(0, isMacOS ? 36 : 40),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(isMacOS ? 10 : 16),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: colorScheme.inverseSurface,
          contentTextStyle: TextStyle(
            color: colorScheme.onInverseSurface,
          ),
        ),
        dividerTheme: DividerThemeData(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          thickness: 1,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white.withValues(alpha: isMacOS ? 0.72 : 0.96),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(isMacOS ? 22 : 24),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: Colors.white.withValues(alpha: isMacOS ? 0.96 : 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(isMacOS ? 14 : 18),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.9),
            ),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: colorScheme.surface,
          indicatorColor: colorScheme.secondaryContainer,
          labelTextStyle:
              WidgetStateProperty.resolveWith((Set<WidgetState> states) {
            final bool selected = states.contains(WidgetState.selected);
            return TextStyle(
              color: selected
                  ? colorScheme.onSecondaryContainer
                  : colorScheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            );
          }),
        ),
      ),
      home: const HomePage(),
    );
  }
}
