import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart' hide Clip;
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/param_value.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/inspector/inspector_effects_tab.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/timeline/timeline_clip_tile.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/timeline/timeline_panel.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';
import 'temp_dir.dart';

/// KEY-7 from the inspector's side: a keyframe on an *effect* parameter can be
/// walked to, retimed by hand and — the part that was missing entirely —
/// deleted. Only the transform rows used to offer any of that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('cc-keyframe-editing');
  });

  tearDownAll(() => deleteTempDir(tmp));

  (EditorController, Clip) harness() {
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
      path: '${tmp.path}/keyframes.crazycut',
    );
    controller.selection.add(clip.id);
    return (controller, clip);
  }

  Widget subject(EditorController controller, Clip clip) => Directionality(
    textDirection: TextDirection.ltr,
    child: Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (_) => Center(
            child: SizedBox(
              width: 320,
              height: 700,
              child: SingleChildScrollView(
                child: EffectsTab(controller: controller, clip: clip),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  ParamValue radius(EditorController c, String fxId) => ParamValue.from(
    ((c.clipById('clip')!.effects.first as Map)['params']
        as Map<String, dynamic>)['radius'],
  );

  testWidgets('an effect keyframe can be deleted from its diamond', (
    tester,
  ) async {
    final (controller, clip) = harness();
    final fxId = controller.addEffect('clip', 'gaussianBlur');
    controller.setKeyframeValue('clip', fxId, 'radius', Rt.zero(), 0.0);
    controller.setKeyframeValue(
      'clip',
      fxId,
      'radius',
      Rt.fromSeconds(2),
      40.0,
    );
    controller.seekTo(Rt.fromSeconds(2));
    expect(radius(controller, fxId).keyframes, hasLength(2));

    await tester.pumpWidget(subject(controller, clip));
    await tester.tap(find.byType(KeyframeDiamond).first, buttons: 2);
    await tester.pumpAndSettle();

    expect(find.text('Delete keyframe'), findsOneWidget);
    await tester.tap(find.text('Delete keyframe'));
    await tester.pumpAndSettle();

    expect(radius(controller, fxId).keyframes, hasLength(1));
    expect(
      ParamValue.timeOf(radius(controller, fxId).keyframes.single),
      Rt.zero(),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('delete is offered only where a key actually is', (tester) async {
    final (controller, clip) = harness();
    final fxId = controller.addEffect('clip', 'gaussianBlur');
    controller.setKeyframeValue('clip', fxId, 'radius', Rt.zero(), 0.0);
    controller.setKeyframeValue(
      'clip',
      fxId,
      'radius',
      Rt.fromSeconds(2),
      40.0,
    );
    controller.seekTo(Rt.fromSeconds(1));

    await tester.pumpWidget(subject(controller, clip));
    await tester.tap(find.byType(KeyframeDiamond).first, buttons: 2);
    await tester.pumpAndSettle();

    // Between two keys: both neighbours are reachable and the whole track can
    // still be cleared, but delete is inert — there is no key here to remove.
    expect(find.text('Previous keyframe'), findsOneWidget);
    expect(find.text('Next keyframe'), findsOneWidget);
    expect(find.text('Clear all keyframes'), findsOneWidget);

    await tester.tap(find.text('Delete keyframe'));
    await tester.pumpAndSettle();
    expect(radius(controller, fxId).keyframes, hasLength(2));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('an animated effect row reads the value under the playhead', (
    tester,
  ) async {
    final (controller, clip) = harness();
    final fxId = controller.addEffect('clip', 'gaussianBlur');
    controller.setKeyframeValue('clip', fxId, 'radius', Rt.zero(), 0.0);
    controller.setKeyframeValue(
      'clip',
      fxId,
      'radius',
      Rt.fromSeconds(4),
      40.0,
    );
    controller.seekTo(Rt.fromSeconds(2));

    await tester.pumpWidget(subject(controller, clip));

    // Halfway along a linear ramp, not the resting static.
    expect(find.text('20.0'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('the timeline shows a clip\'s keyframes and deletes one', (
    tester,
  ) async {
    final (controller, _) = harness();
    const pxPerSec = 100.0;
    final fxId = controller.addEffect('clip', 'gaussianBlur');
    controller.setKeyframeValue('clip', fxId, 'radius', Rt.zero(), 0.0);
    controller.setKeyframeValue(
      'clip',
      fxId,
      'radius',
      Rt.fromSeconds(2),
      40.0,
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (_) => SizedBox(
                width: 1200,
                height: 500,
                child: TimelinePanel(
                  controller: controller,
                  pxPerSec: pxPerSec,
                  snap: false,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final ribbon = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is KeyframeRibbonPainter,
    );
    expect(ribbon, findsOneWidget);
    final painter =
        tester.widget<CustomPaint>(ribbon).painter as KeyframeRibbonPainter;
    expect(painter.seconds, [0.0, 2.0]);

    // Right-click the diamond at two seconds and delete it.
    final at =
        tester.getTopLeft(ribbon) +
        const Offset(2 * pxPerSec, kKeyframeRibbonHeight / 2);
    await tester.tapAt(at, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('Delete keyframe'), findsOneWidget);
    await tester.tap(find.text('Delete keyframe'));
    await tester.pumpAndSettle();

    expect(radius(controller, fxId).keyframes, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
