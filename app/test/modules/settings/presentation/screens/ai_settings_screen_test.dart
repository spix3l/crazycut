import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/app/dependencies.dart';
import 'package:crazycut_app/modules/settings/presentation/screens/ai_settings_screen.dart';

void main() {
  testWidgets('settings navigation exposes non-AI configuration', (
    tester,
  ) async {
    await tester.pumpWidget(
      AppDependenciesScope(
        dependencies: AppDependencies.production(),
        child: WidgetsApp(
          color: const Color(0xFF141518),
          pageRouteBuilder:
              <T>(settings, builder) => PageRouteBuilder<T>(
                settings: settings,
                pageBuilder: (context, _, _) => builder(context),
              ),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Canvas'), findsOneWidget);
    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Shortcuts'), findsOneWidget);
    expect(find.text('AI assist'), findsWidgets);

    await tester.tap(find.text('Playback'));
    await tester.pump();
    expect(find.text('Generate proxies automatically'), findsOneWidget);

    await tester.tap(find.text('Shortcuts'));
    await tester.pump();
    expect(find.text('Play / pause'), findsOneWidget);
    expect(find.text('Space'), findsOneWidget);
  });
}
