import 'package:crazycut_app/ui/browser.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const CrazyCutApp());
}

class CrazyCutApp extends StatelessWidget {
  const CrazyCutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CrazyCut',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF141518),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF5A5F),
          brightness: Brightness.dark,
          surface: const Color(0xFF1D1F23),
        ),
        fontFamilyFallback: const ['Menlo', 'Segoe UI'],
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      home: const ProjectBrowserScreen(),
    );
  }
}
