// dart format width=80
// GENERATED CODE - DO NOT MODIFY BY HAND

// **************************************************************************
// AutoRouterGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:auto_route/auto_route.dart' as _i5;
import 'package:crazycut_app/features/editor/presentation/screens/editor_screen.dart'
    as _i1;
import 'package:crazycut_app/features/export/presentation/screens/export_dialog_screen.dart'
    as _i2;
import 'package:crazycut_app/features/projects/presentation/screens/new_project_dialog_screen.dart'
    as _i3;
import 'package:crazycut_app/features/projects/presentation/screens/project_browser_screen.dart'
    as _i4;
import 'package:flutter/widgets.dart' as _i6;

/// generated route for
/// [_i1.EditorScreen]
class EditorRoute extends _i5.PageRouteInfo<void> {
  const EditorRoute({List<_i5.PageRouteInfo>? children})
    : super(EditorRoute.name, initialChildren: children);

  static const String name = 'EditorRoute';

  static _i5.PageInfo page = _i5.PageInfo(
    name,
    builder: (data) {
      return const _i1.EditorScreen();
    },
  );
}

/// generated route for
/// [_i2.ExportDialogScreen]
class ExportRoute extends _i5.PageRouteInfo<ExportRouteArgs> {
  ExportRoute({
    _i6.Key? key,
    bool empty = false,
    List<_i5.PageRouteInfo>? children,
  }) : super(
         ExportRoute.name,
         args: ExportRouteArgs(key: key, empty: empty),
         rawQueryParams: {'empty': empty},
         initialChildren: children,
       );

  static const String name = 'ExportRoute';

  static _i5.PageInfo page = _i5.PageInfo(
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

  final _i6.Key? key;

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
class NewProjectRoute extends _i5.PageRouteInfo<void> {
  const NewProjectRoute({List<_i5.PageRouteInfo>? children})
    : super(NewProjectRoute.name, initialChildren: children);

  static const String name = 'NewProjectRoute';

  static _i5.PageInfo page = _i5.PageInfo(
    name,
    builder: (data) {
      return const _i3.NewProjectDialogScreen();
    },
  );
}

/// generated route for
/// [_i4.ProjectBrowserScreen]
class ProjectBrowserRoute extends _i5.PageRouteInfo<void> {
  const ProjectBrowserRoute({List<_i5.PageRouteInfo>? children})
    : super(ProjectBrowserRoute.name, initialChildren: children);

  static const String name = 'ProjectBrowserRoute';

  static _i5.PageInfo page = _i5.PageInfo(
    name,
    builder: (data) {
      return const _i4.ProjectBrowserScreen();
    },
  );
}
