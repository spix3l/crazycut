import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/projects/presentation/widgets/browser_header.dart';

void main() {
  testWidgets('project browser header exposes open and new project actions', (
    tester,
  ) async {
    var opened = false;
    var created = false;
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        builder:
            (context, child) => BrowserHeader(
              showSearch: false,
              onOpenProject: () => opened = true,
              onNewProject: () => created = true,
            ),
      ),
    );

    await tester.tap(find.text('Open Project'));
    await tester.tap(find.text('New Project'));

    expect(opened, isTrue);
    expect(created, isTrue);
  });
}
