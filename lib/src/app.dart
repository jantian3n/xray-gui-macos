import 'package:flutter/material.dart';

import 'features/home/presentation/home_page.dart';

class XrayGuiApp extends StatelessWidget {
  const XrayGuiApp({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF006A64),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'Xray GUI macOS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: colorScheme.surface,
        appBarTheme: AppBarTheme(
          elevation: 0,
          centerTitle: false,
          backgroundColor: colorScheme.surface,
          foregroundColor: colorScheme.onSurface,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(color: colorScheme.primary),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: colorScheme.inverseSurface,
          contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: colorScheme.surface,
          indicatorColor: colorScheme.secondaryContainer,
          labelTextStyle: WidgetStateProperty.resolveWith((
            Set<WidgetState> states,
          ) {
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
