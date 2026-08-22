import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('CcTooltip overlay stays content-sized', (tester) async {
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        // WidgetsApp asserts one of builder/onGenerateRoute/pageRouteBuilder.
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: Center(
          child: CcTooltip(
            message: 'Split at playhead',
            delay: Duration.zero,
            child: const SizedBox(width: 24, height: 24),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(CcTooltip)));
    await tester.pumpAndSettle();

    final bubble = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.padding == const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    );

    expect(find.text('Split at playhead'), findsOneWidget);
    expect(bubble, findsOneWidget);
    expect(tester.getSize(bubble).width, lessThan(200));
    expect(tester.getSize(bubble).height, lessThan(50));
  });

  testWidgets('CcTooltip stays inside the viewport at an edge', (tester) async {
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: const Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.only(left: 2, top: 40),
            child: CcTooltip(
              message: 'Split at playhead (S)',
              delay: Duration.zero,
              child: SizedBox(width: 24, height: 24),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(CcTooltip)));
    await tester.pumpAndSettle();

    final bubble = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.padding == const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    );

    expect(tester.getTopLeft(bubble).dx, greaterThanOrEqualTo(8));
    expect(tester.getTopLeft(bubble).dy, greaterThanOrEqualTo(8));
  });

  testWidgets('CcMenu stays clear of viewport edges', (tester) async {
    const host = Key('menu-host');
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: const SizedBox(key: host),
      ),
    );

    await tester.pumpAndSettle();
    showCcMenu(
      tester.element(find.byKey(host)),
      const Offset(0, 600),
      const [
        CcMenuItem('Rename'),
        CcMenuItem('Cycle height'),
        CcMenuItem('Move up'),
        CcMenuItem('Move down'),
      ],
    );
    await tester.pump();

    final menuRect = tester.getRect(find.byType(CcMenu));
    final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(menuRect.left, greaterThanOrEqualTo(20));
    expect(menuRect.top, greaterThanOrEqualTo(20));
    expect(menuRect.right, lessThanOrEqualTo(viewport.width - 20));
    expect(menuRect.bottom, lessThanOrEqualTo(viewport.height - 20));
  });
}
