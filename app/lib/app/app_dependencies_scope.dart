part of 'dependencies.dart';

class AppDependenciesScope extends InheritedWidget {
  const AppDependenciesScope({
    super.key,
    required this.dependencies,
    required super.child,
  });

  final AppDependencies dependencies;

  static AppDependencies of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppDependenciesScope>();
    if (scope == null) {
      throw StateError('AppDependenciesScope is missing above this context');
    }
    return scope.dependencies;
  }

  static AppDependencies read(BuildContext context) {
    final element =
        context.getElementForInheritedWidgetOfExactType<AppDependenciesScope>();
    final scope = element?.widget as AppDependenciesScope?;
    if (scope == null) {
      throw StateError('AppDependenciesScope is missing above this context');
    }
    return scope.dependencies;
  }

  @override
  bool updateShouldNotify(AppDependenciesScope oldWidget) =>
      dependencies != oldWidget.dependencies;
}
