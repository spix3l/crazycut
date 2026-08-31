import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/app/router/app_router.dart';
import 'package:crazycut_app/app/dependencies.dart';
import 'package:crazycut_app/modules/project/infrastructure/repository.dart';
import '../../support/temp_dir.dart';

void main() {
  testWidgets('browser picks up a project created while it was covered', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('cc_browser');
    addTearDown(() {
      ProjectRepository.rootOverride = null;
      deleteTempDir(root);
    });
    ProjectRepository.rootOverride = root;

    // The browser is a desktop layout; the default test surface clips it.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The test font is wider than the shipped one, so the welcome cards spill
    // by a few pixels. Layout is not what this test is about.
    final onError = FlutterError.onError;
    addTearDown(() => FlutterError.onError = onError);
    FlutterError.onError = (details) {
      if (details.exception.toString().startsWith('A RenderFlex overflowed')) {
        return;
      }
      onError?.call(details);
    };

    final router = AppRouter();
    final dependencies = AppDependencies.production();
    await tester.pumpWidget(
      AppDependenciesScope(
        dependencies: dependencies,
        child: MaterialApp.router(routerConfig: router.config()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Start cutting'), findsOneWidget);

    // What the new-project dialog does, then what the editor's back button
    // does. The dialog replaces its own route with the editor, so the browser
    // never sees its push future complete.
    await tester.runAsync(() async {
      await dependencies.session.createNew(
        name: 'Fresh cut',
        width: 1920,
        height: 1080,
        fps: 30,
      );
      await dependencies.session.close();
      // The browser reloads off disk; let that real IO finish.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump();

    expect(find.text('Start cutting'), findsNothing);
    expect(find.text('Fresh cut'), findsOneWidget);
  });
}
