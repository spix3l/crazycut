import 'package:flutter/widgets.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'dependencies.dart';
import 'platform_menu.dart';
import 'router/app_router.dart';

/// Application root. Deliberately not a `MaterialApp`: CrazyCut ships its own
/// design system, so it only needs the plumbing `WidgetsApp` provides.
class CrazyCutApp extends StatefulWidget {
  const CrazyCutApp({super.key, required this.dependencies});

  final AppDependencies dependencies;

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
    widget.dependencies.aiSettings.load().whenComplete(() {
      if (mounted) setState(() {});
    });
    widget.dependencies.preferences.load().then((_) {
      widget.dependencies.session.proxies.enabled =
          widget.dependencies.preferences.generateProxies;
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

    return AppDependenciesScope(
      dependencies: widget.dependencies,
      child: CrazyCutMenuBar(
        router: _router,
        session: widget.dependencies.session,
        child: app,
      ),
    );
  }
}
