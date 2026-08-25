import 'package:auto_route/auto_route.dart';

import 'app_router.gr.dart';

/// Root navigation graph. Dialogs are real routes rendered on top of the
/// screen they were opened from (`opaque: false`), so the browser / editor
/// underneath stays visible and mounted.
@AutoRouterConfig()
class AppRouter extends RootStackRouter {
  @override
  List<AutoRoute> get routes => [
    CustomRoute(
      page: ProjectBrowserRoute.page,
      path: '/',
      initial: true,
      transitionsBuilder: TransitionsBuilders.fadeIn,
      duration: const Duration(milliseconds: 150),
    ),
    CustomRoute(
      page: EditorRoute.page,
      path: '/editor',
      transitionsBuilder: TransitionsBuilders.fadeIn,
      duration: const Duration(milliseconds: 150),
    ),
    CustomRoute(
      page: NewProjectRoute.page,
      path: '/new-project',
      opaque: false,
      barrierDismissible: true,
      transitionsBuilder: TransitionsBuilders.fadeIn,
      duration: const Duration(milliseconds: 120),
    ),
    CustomRoute(
      page: ExportRoute.page,
      path: '/editor/export',
      opaque: false,
      barrierDismissible: true,
      transitionsBuilder: TransitionsBuilders.fadeIn,
      duration: const Duration(milliseconds: 120),
    ),
    CustomRoute(
      page: ShortsReviewRoute.page,
      path: '/editor/shorts',
      opaque: false,
      barrierDismissible: true,
      transitionsBuilder: TransitionsBuilders.fadeIn,
      duration: const Duration(milliseconds: 120),
    ),
    CustomRoute(
      page: SettingsRoute.page,
      path: '/settings',
      opaque: false,
      barrierDismissible: true,
      transitionsBuilder: TransitionsBuilders.fadeIn,
      duration: const Duration(milliseconds: 120),
    ),
  ];
}
