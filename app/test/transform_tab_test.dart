import 'dart:io';

import 'package:flutter/widgets.dart' hide Clip;
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/text_content.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/inspector/inspector_transform_tab.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('cc-transform-tab');
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  (EditorController, Clip) videoHarness() {
    final doc = ProjectDoc.empty('P', width: 1920, height: 1080, fps: 30);
    doc.media.add(
      MediaAsset(
        id: 'video',
        name: 'interview.mov',
        path: '/tmp/interview.mov',
        type: 'video',
        duration: Rt.fromSeconds(12),
        hasAudio: true,
        width: 1920,
        height: 1080,
      ),
    );
    final clip = Clip(
      id: 'clip',
      trackId: doc.videoTrack()!.id,
      mediaId: 'video',
      label: 'Interview',
      start: Rt.zero(),
      duration: Rt.fromSeconds(6),
      sourceIn: Rt.zero(),
    );
    doc.clips.add(clip);
    final controller = EditorController(
      doc,
      path: '${tmp.path}/transform-tab.crazycut',
    );
    controller.selection.add(clip.id);
    return (controller, clip);
  }

  (EditorController, Clip) textHarness() {
    final doc = ProjectDoc.empty('P', width: 1920, height: 1080, fps: 30);
    final clip = Clip(
      id: 'title',
      trackId: doc.videoTrack()!.id,
      mediaId: '',
      label: 'Title',
      start: Rt.zero(),
      duration: Rt.fromSeconds(5),
      sourceIn: Rt.zero(),
      text: TextContent(content: 'Chapter one'),
    );
    doc.clips.add(clip);
    final controller = EditorController(
      doc,
      path: '${tmp.path}/text-transform-tab.crazycut',
    );
    controller.selection.add(clip.id);
    return (controller, clip);
  }

  Widget subject(EditorController controller, Clip clip) => WidgetsApp(
    color: const Color(0xFF141518),
    builder:
        (context, child) => Center(
          child: SizedBox(
            width: 300,
            height: 760,
            child: SingleChildScrollView(
              child: TransformTab(controller: controller, clip: clip),
            ),
          ),
        ),
  );

  testWidgets('video transform tab exposes explicit enter and leave controls', (
    tester,
  ) async {
    final (controller, clip) = videoHarness();
    addTearDown(controller.dispose);

    await tester.pumpWidget(subject(controller, clip));

    expect(find.text('CLIP ANIMATION'), findsOneWidget);
    expect(find.text('Enter'), findsOneWidget);
    expect(find.text('At clip start'), findsOneWidget);
    expect(find.text('Leave'), findsOneWidget);
    expect(find.text('At clip end'), findsOneWidget);
    expect(find.text('LAYOUT'), findsOneWidget);
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('CONTINUOUS MOTION'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('text transform tab uses the same edge animation structure', (
    tester,
  ) async {
    final (controller, clip) = textHarness();
    addTearDown(controller.dispose);

    await tester.pumpWidget(subject(controller, clip));

    expect(find.text('CLIP ANIMATION'), findsOneWidget);
    expect(find.text('Enter'), findsOneWidget);
    expect(find.text('Leave'), findsOneWidget);
    expect(find.text('CONTINUOUS MOTION'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
