import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/data/template.dart';
import 'package:crazycut_app/data/template_library.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/media_pool.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the templates tab lists the library and offers capture', (
    tester,
  ) async {
    print('STEP start');
    final temp = Directory.systemTemp.createTempSync('cc_templates_panel');
    ProjectRepository.rootOverride = temp;
    TemplateLibrary.instance.resetForTest();

    await TemplateLibrary.instance.save(
      ClipTemplate(
        id: 'tpl-1',
        name: 'Section bumper',
        category: 'Bumpers',
        createdAt: DateTime.now().toUtc(),
        clips: [
          {
            'id': 'c1',
            'trackId': 'lane',
            'mediaId': '',
            'label': 'Text',
            'start': '0/1',
            'duration': '3/1',
            'sourceIn': '0/1',
          },
        ],
        lanes: [TemplateLane(key: 'lane', kind: 'video', offset: 0)],
      ),
    );

    final doc = ProjectDoc.empty('Proj', width: 1920, height: 1080, fps: 30);
    final controller = EditorController(
      doc,
      path: '${temp.path}/proj.crazycut',
    );
    addTearDown(() async {
      await controller.close();
      ProjectRepository.rootOverride = null;
      TemplateLibrary.instance.resetForTest();
      temp.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, _) => builder(context),
        ),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: MediaPool.width,
            height: 700,
            child: MediaPool(controller: controller),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Templates'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    print('STEP tabbed');
    expect(find.text('Section bumper'), findsOneWidget);
    expect(find.text('3.0s'), findsOneWidget);
    expect(find.textContaining('Bumpers'), findsOneWidget);

    print('STEP card ok');
    // Capture needs a selection; without one it says so rather than opening an
    // empty dialog.
    await tester.tap(find.text('Save selection as template'));
    await tester.pump();
    expect(find.text('Select clips on the timeline first'), findsOneWidget);

    print('STEP status ok');
    // The media tab is still there and still works.
    await tester.tap(find.text('Media'));
    await tester.pump();
    expect(find.text('Section bumper'), findsNothing);
  });

  testWidgets('an empty library explains what a template is for', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('cc_templates_empty');
    ProjectRepository.rootOverride = temp;
    TemplateLibrary.instance.resetForTest();

    final doc = ProjectDoc.empty('Proj', width: 1920, height: 1080, fps: 30);
    doc.media.add(
      MediaAsset(
        id: 'm1',
        name: 'clip.mov',
        path: '${temp.path}/clip.mov',
        type: 'video',
        duration: Rt.fromSeconds(5),
        hasAudio: false,
      ),
    );
    final controller = EditorController(
      doc,
      path: '${temp.path}/proj.crazycut',
    );
    addTearDown(() async {
      await controller.close();
      ProjectRepository.rootOverride = null;
      TemplateLibrary.instance.resetForTest();
      temp.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, _) => builder(context),
        ),
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: MediaPool.width,
            height: 700,
            child: MediaPool(controller: controller),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Templates'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('No templates yet'), findsOneWidget);
  });
}
