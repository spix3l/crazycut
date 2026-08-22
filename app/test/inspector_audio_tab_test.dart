import 'dart:io';

import 'package:flutter/widgets.dart' hide Clip;
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/inspector/inspector_panel.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('cc-inspector-audio');
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<void> expectAudioControls(
    WidgetTester tester, {
    required String assetType,
  }) async {
    final doc = ProjectDoc.empty('Audio inspector', fps: 30);
    final asset = MediaAsset(
      id: 'media',
      name: assetType == 'audio' ? 'music.wav' : 'interview.mov',
      path: '',
      type: assetType,
      duration: Rt.fromSeconds(10),
      hasAudio: true,
      width: assetType == 'video' ? 1920 : null,
      height: assetType == 'video' ? 1080 : null,
    );
    doc.media.add(asset);
    final clip = Clip(
      id: 'clip',
      trackId:
          assetType == 'audio'
              ? doc.audioTrack()!.id
              : doc.videoTrack()!.id,
      mediaId: asset.id,
      label: asset.name,
      start: Rt.zero(),
      duration: Rt.fromSeconds(5),
      sourceIn: Rt.zero(),
    );
    doc.clips.add(clip);
    final controller = EditorController(
      doc,
      path: '${tmp.path}/$assetType.crazycut',
    );
    controller.selection.add(clip.id);

    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF141518),
        builder:
            (context, child) => Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                height: 700,
                child: InspectorPanel(controller: controller),
              ),
            ),
      ),
    );
    await tester.tap(find.text('Audio'));
    await tester.pump();

    expect(find.text('LEVELS'), findsOneWidget);
    expect(find.text('Volume'), findsOneWidget);
    expect(find.text('Pan'), findsOneWidget);
    expect(find.text('FADES'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }

  testWidgets('video clips with audio expose clip audio controls', (
    tester,
  ) async {
    await expectAudioControls(tester, assetType: 'video');
  });

  testWidgets('standalone audio clips expose clip audio controls', (
    tester,
  ) async {
    await expectAudioControls(tester, assetType: 'audio');
  });
}
