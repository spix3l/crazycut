import 'package:crazycut_app/app/help_dialog.dart';
import 'package:crazycut_app/app/dependencies.dart';
import 'package:crazycut_app/app/platform_menu.dart';
import 'package:crazycut_app/app/router/app_router.dart';
import 'package:crazycut_app/core/design/tokens.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Searches the serialized platform-menu tree for an item by label.
Map<Object?, Object?>? findMenuItem(Object? node, String label) {
  if (node is Map<Object?, Object?>) {
    if (node['label'] == label) return node;
    for (final value in node.values) {
      final hit = findMenuItem(value, label);
      if (hit != null) return hit;
    }
  } else if (node is List) {
    for (final value in node) {
      final hit = findMenuItem(value, label);
      if (hit != null) return hit;
    }
  }
  return null;
}

void main() {
  testWidgets('help dialog shows getting started and shortcuts', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        navigatorKey: navigatorKey,
        pageRouteBuilder:
            <T>(settings, builder) => PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: const SizedBox.shrink(),
      ),
    );

    showHelpDialog(
      navigatorKey.currentContext!,
      overlay: navigatorKey.currentState!.overlay,
    );
    await tester.pump();

    expect(find.text('CrazyCut Help'), findsOneWidget);
    expect(find.text('Getting started'), findsOneWidget);
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Split at playhead'), findsOneWidget);
    expect(find.text('Shuttle backward / stop / forward'), findsOneWidget);
    expect(find.text('⇧⌘S'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(find.text('Split at playhead'), findsNothing);
  });

  testWidgets('help dialog closes on Escape', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      WidgetsApp(
        color: CcColors.bg,
        navigatorKey: navigatorKey,
        pageRouteBuilder:
            <T>(settings, builder) => PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: const SizedBox.shrink(),
      ),
    );

    showHelpDialog(
      navigatorKey.currentContext!,
      overlay: navigatorKey.currentState!.overlay,
    );
    await tester.pump();
    expect(find.text('Split at playhead'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Split at playhead'), findsNothing);
  });

  testWidgets('macOS menu bar wires Help ▸ CrazyCut Help to the dialog', (
    tester,
  ) async {
    // The binding checks its foundation invariants before package-level
    // tearDowns run, so the override has to be cleared within the body.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _exerciseHelpMenu(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// Pumps the menu bar over a minimal app on the router's navigator key:
/// enough for the Help item to resolve the Overlay when it fires, without
/// booting a real screen. Then it triggers the item the way macOS does.
Future<void> _exerciseHelpMenu(WidgetTester tester) async {
  final setMenus = <Object?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.menu,
    (call) async {
      if (call.method == 'Menu.setMenus') {
        final window = call.arguments! as Map<Object?, Object?>;
        setMenus.add(window['0']);
      }
      return null;
    },
  );

  // A minimal app on the router's navigator key: enough for the menu bar to
  // resolve the Overlay when Help fires, without booting a real screen.
  final router = AppRouter();
  final dependencies = AppDependencies.production();
  await tester.pumpWidget(
    CrazyCutMenuBar(
      router: router,
      session: dependencies.session,
      child: WidgetsApp(
        color: CcColors.bg,
        navigatorKey: router.navigatorKey,
        pageRouteBuilder:
            <T>(settings, builder) => PageRouteBuilder<T>(
              settings: settings,
              pageBuilder: (context, _, _) => builder(context),
            ),
        home: const SizedBox.shrink(),
      ),
    ),
  );
  await tester.pump();

  expect(setMenus, isNotEmpty, reason: 'the menu bar should have registered');
  final helpItem = findMenuItem(setMenus.last, 'CrazyCut Help');
  expect(
    helpItem,
    isNotNull,
    reason: 'Help menu should carry a CrazyCut Help item',
  );

  // Trigger the item the way macOS does: a selectedCallback for its id.
  final encoded = SystemChannels.menu.codec.encodeMethodCall(
    MethodCall('Menu.selectedCallback', helpItem!['id']),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.menu.name,
    encoded,
    (ByteData? data) {},
  );
  await tester.pump();

  expect(find.text('CrazyCut Help'), findsOneWidget);
  expect(find.text('Split at playhead'), findsOneWidget);
}
