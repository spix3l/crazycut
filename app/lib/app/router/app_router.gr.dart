// dart format width=80
// GENERATED CODE - DO NOT MODIFY BY HAND

// **************************************************************************
// AutoRouterGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:auto_route/auto_route.dart' as _i7;
import 'package:crazycut_app/features/editor/presentation/screens/editor_screen.dart'
    as _i1;
import 'package:crazycut_app/features/export/presentation/screens/export_dialog_screen.dart'
    as _i2;
import 'package:crazycut_app/features/projects/presentation/screens/new_project_dialog_screen.dart'
    as _i3;
import 'package:crazycut_app/features/projects/presentation/screens/project_browser_screen.dart'
    as _i4;
import 'package:crazycut_app/features/settings/presentation/screens/ai_settings_screen.dart'
    as _i5;
import 'package:crazycut_app/features/shorts/presentation/screens/shorts_review_screen.dart'
    as _i6;
import 'package:flutter/widgets.dart' as _i8;

/// generated route for
/// [_i1.EditorScreen]
class EditorRoute extends _i7.PageRouteInfo<void> {
  const EditorRoute({List<_i7.PageRouteInfo>? children})
    : super(EditorRoute.name, initialChildren: children);

  static const String name = 'EditorRoute';

  static _i7.PageInfo page = _i7.PageInfo(
    name,
    builder: (data) {
      return const _i1.EditorScreen();
    },
  );
}

/// generated route for
/// [_i2.ExportDialogScreen]
class ExportRoute extends _i7.PageRouteInfo<ExportRouteArgs> {
  ExportRoute({
    _i8.Key? key,
    bool empty = false,
    List<_i7.PageRouteInfo>? children,
  }) : super(
         ExportRoute.name,
         args: ExportRouteArgs(key: key, empty: empty),
         rawQueryParams: {'empty': empty},
         initialChildren: children,
       );

  static const String name = 'ExportRoute';

  static _i7.PageInfo page = _i7.PageInfo(
    name,
    builder: (data) {
      final queryParams = data.queryParams;
      final args = data.argsAs<ExportRouteArgs>(
        orElse: () =>
            ExportRouteArgs(empty: queryParams.getBool('empty', false)),
      );
      return _i2.ExportDialogScreen(key: args.key, empty: args.empty);
    },
  );
}

class ExportRouteArgs {
  const ExportRouteArgs({this.key, this.empty = false});

  final _i8.Key? key;

  final bool empty;

  @override
  String toString() {
    return 'ExportRouteArgs{key: $key, empty: $empty}';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ExportRouteArgs) return false;
    return key == other.key && empty == other.empty;
  }

  @override
  int get hashCode => key.hashCode ^ empty.hashCode;
}

/// generated route for
/// [_i3.NewProjectDialogScreen]
class NewProjectRoute extends _i7.PageRouteInfo<void> {
  const NewProjectRoute({List<_i7.PageRouteInfo>? children})
    : super(NewProjectRoute.name, initialChildren: children);

  static const String name = 'NewProjectRoute';

  static _i7.PageInfo page = _i7.PageInfo(
    name,
    builder: (data) {
      return const _i3.NewProjectDialogScreen();
    },
  );
}

/// generated route for
/// [_i4.ProjectBrowserScreen]
class ProjectBrowserRoute extends _i7.PageRouteInfo<void> {
  const ProjectBrowserRoute({List<_i7.PageRouteInfo>? children})
    : super(ProjectBrowserRoute.name, initialChildren: children);

  static const String name = 'ProjectBrowserRoute';

  static _i7.PageInfo page = _i7.PageInfo(
    name,
    builder: (data) {
      return const _i4.ProjectBrowserScreen();
    },
  );
}

/// generated route for
/// [_i5.SettingsScreen]
class SettingsRoute extends _i7.PageRouteInfo<void> {
  const SettingsRoute({List<_i7.PageRouteInfo>? children})
    : super(SettingsRoute.name, initialChildren: children);

  static const String name = 'SettingsRoute';

  static _i7.PageInfo page = _i7.PageInfo(
    name,
    builder: (data) {
      return const _i5.SettingsScreen();
    },
  );
}

/// generated route for
/// [_i6.ShortsReviewScreen]
class ShortsReviewRoute extends _i7.PageRouteInfo<void> {
  const ShortsReviewRoute({List<_i7.PageRouteInfo>? children})
    : super(ShortsReviewRoute.name, initialChildren: children);

  static const String name = 'ShortsReviewRoute';

  static _i7.PageInfo page = _i7.PageInfo(
    name,
    builder: (data) {
      return const _i6.ShortsReviewScreen();
    },
  );
}
