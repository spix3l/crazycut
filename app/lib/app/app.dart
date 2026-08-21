import 'package:flutter/widgets.dart';

import '../core/design/tokens.dart';
import 'router/app_router.dart';

/// Application root. Deliberately not a `MaterialApp`: CrazyCut ships its own
/// design system, so it only needs the plumbing `WidgetsApp` provides.
class CrazyCutApp extends StatefulWidget {
  const CrazyCutApp({super.key});

  @override
  State<CrazyCutApp> createState() => _CrazyCutAppState();
}

class _CrazyCutAppState extends State<CrazyCutApp> {
  final _router = AppRouter();

  @override
  Widget build(BuildContext context) {
    return WidgetsApp.router(
      title: 'CrazyCut',
      color: CcColors.accent,
      routerConfig: _router.config(),
      textStyle: CcType.base,
      debugShowCheckedModeBanner: false,
      builder: (context, child) => ColoredBox(
        color: CcColors.bg,
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
