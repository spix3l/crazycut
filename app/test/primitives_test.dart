import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('full-width dropdown keeps its chevron at the trailing edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 300,
            child: CcDropdown(
              value: 'Haut-parleurs MacBook Air',
              width: double.infinity,
            ),
          ),
        ),
      ),
    );

    final dropdown = tester.getRect(find.byType(CcDropdown));
    final chevron = tester.getRect(find.byType(CcIcon));
    expect(chevron.right, dropdown.right - 10);
    expect(chevron.left, greaterThan(dropdown.center.dx));
  });

  testWidgets('CcMultilineTextField works below WidgetsApp', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: Center(
          child: SizedBox(
            width: 240,
            child: CcMultilineTextField(
              controller: controller,
              placeholder: 'Type…',
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Type…'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'First line\nSecond line');
    await tester.pump();

    expect(controller.text, 'First line\nSecond line');
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('CcTappable activates on Enter/Space and shows a focus ring', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: Center(
          child: CcTappable(
            onTap: () => taps++,
            child: const SizedBox(width: 60, height: 30),
          ),
        ),
      ),
    );

    final target = find.byType(CcTappable);
    // Tab to it, then activate with Enter and Space.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(taps, 2);

    // The focus ring appears while focused.
    expect(
      find.descendant(
        of: target,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration! as BoxDecoration).border != null &&
              (widget.decoration! as BoxDecoration).border ==
                  Border.all(color: CcColors.accent, width: 2),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('CcTappable ignores arrows and moves focus between siblings', (
    tester,
  ) async {
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: Row(
          children: [
            for (var i = 0; i < 3; i++)
              CcTappable(
                onTap: () {},
                child: SizedBox(width: 30, height: 30, key: ValueKey('tap-$i')),
              ),
          ],
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    // Focus moved to the second tappable (the second child is now focused).
    final focus0 = tester
        .widget<Focus>(
          find.descendant(
            of: find.byType(CcTappable).at(0),
            matching: find.byType(Focus),
          ),
        )
        .focusNode!;
    final focus1 = tester
        .widget<Focus>(
          find.descendant(
            of: find.byType(CcTappable).at(1),
            matching: find.byType(Focus),
          ),
        )
        .focusNode!;
    expect(focus0.hasFocus, isFalse);
    expect(focus1.hasFocus, isTrue);
  });

  testWidgets('CcTooltip shows on keyboard focus, not just hover', (
    tester,
  ) async {
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: Center(
          child: CcTooltip(
            message: 'Split at playhead',
            delay: Duration.zero,
            child: CcTappable(
              onTap: () {},
              child: const SizedBox(width: 24, height: 24),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    // Focus the wrapped control; the tooltip should appear without any mouse.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(find.text('Split at playhead'), findsOneWidget);
  });

  testWidgets('CcButton with no handler renders a disabled state', (tester) async {
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: Center(
          child: CcButton(label: 'Export', onPressed: null),
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('Export'));
    // Disabled foreground is tertiary; enabled primary would be onAccent.
    expect(label.style?.color, CcColors.textTertiary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CcTextField with a label keeps the label visible', (tester) async {
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: Center(
          child: SizedBox(
            width: 220,
            child: CcTextField(
              placeholder: 'Find a project',
              label: 'Search',
              height: 32,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Find a project'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('menu close returns focus to the anchor', (tester) async {
    const host = Key('menu-host');
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: Center(
          child: CcTappable(
            onTap: () {},
            child: const SizedBox(key: host, width: 40, height: 40),
          ),
        ),
      ),
    );

    // Focus the anchor, open the menu, then close it by tapping outside.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    showCcMenu(
      tester.element(find.byKey(host)),
      const [CcMenuItem('Rename'), CcMenuItem('Delete')],
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 400));
    await tester.pumpAndSettle();

    expect(find.byType(CcMenu), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.context?.widget is Focus,
      isTrue,
    );
  });

  testWidgets('CcReveal respects reduced motion', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: WidgetsApp(
          color: CcColors.bg,
          pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
              PageRouteBuilder<T>(
                settings: settings,
                pageBuilder: (context, _, _) => builder(context),
              ),
          home: const CcReveal(
            duration: Duration(milliseconds: 320),
            child: SizedBox(width: 40, height: 40),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    // No TweenAnimationBuilder runs and no Opacity wrapper exists: the child
    // renders directly at full opacity with no translation.
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(
      find.ancestor(
        of: find.byType(SizedBox),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
  });

  testWidgets('CcReveal plays a fade and settles at rest', (tester) async {
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
            PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: const CcReveal(
          duration: Duration(milliseconds: 200),
          child: SizedBox(width: 40, height: 40),
        ),
      ),
    );

    // Mid-animation the reveal is partially transparent.
    await tester.pump(const Duration(milliseconds: 100));
    final midOpacity = tester
        .widget<Opacity>(
          find.ancestor(
            of: find.byType(SizedBox),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;
    expect(midOpacity, greaterThan(0));
    expect(midOpacity, lessThan(1));

    // After settling, full opacity, no translation offset.
    await tester.pumpAndSettle();
    final settledOpacity = tester
        .widget<Opacity>(
          find.ancestor(
            of: find.byType(SizedBox),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;
    expect(settledOpacity, 1.0);
    final translate = tester.widget<Transform>(
      find.ancestor(
        of: find.byType(SizedBox),
        matching: find.byType(Transform),
      ),
    );
    expect(translate.transform.getTranslation().y, 0);
  });
}
