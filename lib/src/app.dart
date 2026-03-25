import 'dart:io';

import 'package:flutter/material.dart';

import 'features/home/presentation/home_page.dart';

class XrayGuiApp extends StatelessWidget {
  const XrayGuiApp({super.key});

  @override
  Widget build(BuildContext context) {
    final bool isMacOS = Platform.isMacOS;
    final ColorScheme colorScheme = ColorScheme.fromSeed(
      seedColor: isMacOS ? const Color(0xFF0A84FF) : const Color(0xFF006A64),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'Xray GUI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        visualDensity: isMacOS ? VisualDensity.compact : VisualDensity.standard,
        scaffoldBackgroundColor:
            isMacOS ? const Color(0xFFF4F5F7) : colorScheme.surface,
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
              ? Colors.white.withValues(alpha: 0.86)
              : colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(isMacOS ? 18 : 28),
            side: isMacOS
                ? BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                  )
                : BorderSide.none,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: isMacOS
              ? Colors.white.withValues(alpha: 0.94)
              : colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(isMacOS ? 14 : 20),
            borderSide: BorderSide(
              color: isMacOS
                  ? colorScheme.outlineVariant.withValues(alpha: 0.55)
                  : Colors.transparent,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(isMacOS ? 14 : 20),
            borderSide: BorderSide(
              color: isMacOS
                  ? colorScheme.outlineVariant.withValues(alpha: 0.55)
                  : Colors.transparent,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(isMacOS ? 14 : 20),
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
          backgroundColor: Colors.white.withValues(alpha: 0.96),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.4),
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
