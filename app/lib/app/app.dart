import 'package:crazycut_app/ai/ai_settings.dart';
import 'package:flutter/widgets.dart';

import '../core/design/tokens.dart';
import 'platform_menu.dart';
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
  void initState() {
    super.initState();
    // Read the AI configuration once at startup so the editor knows whether to
    // show any AI affordance at all (AI-1). A failure here leaves AI off,
    // which is exactly the behaviour we want.
    AiSettings.instance.load().whenComplete(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = WidgetsApp.router(
      title: 'CrazyCut',
      color: CcColors.accent,
      routerConfig: _router.config(),
      textStyle: CcType.base,
      debugShowCheckedModeBanner: false,
      builder:
          (context, child) => ColoredBox(
            color: CcColors.bg,
            child: child ?? const SizedBox.shrink(),
          ),
    );

    return CrazyCutMenuBar(router: _router, child: app);
  }
}
