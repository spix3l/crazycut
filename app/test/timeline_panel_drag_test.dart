import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/timeline/timeline_clip_tile.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/timeline/timeline_panel.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';

void main() {
  testWidgets('dragging a track header reorders its lane', (tester) async {
    final temp = Directory.systemTemp.createTempSync('crazycut-lane-drag-');
    final doc =
        ProjectDoc.empty('Lane drag', width: 1920, height: 1080, fps: 30);
    final first = doc.videoTrack()!;
    final second = Track(id: 'v2', kind: 'video', name: 'V2', index: 1);
    doc.tracks.add(second);
    doc.clips.add(
      Clip(
        id: 'clip',
        trackId: first.id,
        mediaId: 'offline',
        label: 'clip',
        start: Rt.zero(),
        duration: Rt.fromSeconds(1),
        sourceIn: Rt.zero(),
      ),
    );
    final controller =
        EditorController(doc, path: '${temp.path}/timeline.crazycut');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

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
                    controller: controller, pxPerSec: 20, snap: false),
              ),
            ),
          ],
        ),
      ),
    );

    expect(doc.videoTracks.reversed.map((track) => track.id),
        [second.id, first.id]);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey('track-drag-handle-${first.id}'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(tester
        .getCenter(find.byKey(ValueKey('track-drop-target-${second.id}'))));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(doc.videoTracks.reversed.map((track) => track.id),
        [first.id, second.id]);

    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('dragging a selected clip moves the whole selection',
      (tester) async {
    final temp = Directory.systemTemp.createTempSync('crazycut-timeline-drag-');
    final doc =
        ProjectDoc.empty('Timeline drag', width: 1920, height: 1080, fps: 30);
    doc.media.add(
      MediaAsset(
        id: 'asset',
        name: 'offline.mov',
        path: '',
        type: 'video',
        duration: Rt.fromSeconds(30),
        hasAudio: false,
      ),
    );
    final trackId = doc.videoTrack()!.id;
    doc.clips.addAll([
      Clip(
        id: 'a',
        trackId: trackId,
        mediaId: 'asset',
        label: 'a',
        start: Rt.zero(),
        duration: Rt.fromSeconds(4),
        sourceIn: Rt.zero(),
      ),
      Clip(
        id: 'b',
        trackId: trackId,
        mediaId: 'asset',
        label: 'b',
        start: Rt.fromSeconds(6),
        duration: Rt.fromSeconds(4),
        sourceIn: Rt.zero(),
      ),
    ]);
    final controller =
        EditorController(doc, path: '${temp.path}/timeline.crazycut');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    controller.selectClip('a');
    controller.selectClip('b', additive: true);
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
                    controller: controller, pxPerSec: 20, snap: false),
              ),
            ),
          ],
        ),
      ),
    );

    Finder clip(String id) => find.byWidgetPredicate(
        (widget) => widget is TimelineClipTile && widget.clip.id == id);

    GestureDetector clipBody(String id) => tester.widget<GestureDetector>(
          find.ancestor(
            of: clip(id),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is GestureDetector &&
                  widget.onPanStart != null &&
                  widget.onPanUpdate != null,
            ),
          ),
        );

    Future<void> dragClip(String id) async {
      final body = clipBody(id);
      body.onPanStart!(DragStartDetails());
      body.onPanUpdate!(
        DragUpdateDetails(
            globalPosition: const Offset(20, 0), delta: const Offset(20, 0)),
      );
      body.onPanEnd!(DragEndDetails());
      await tester.pump();
    }

    // Pointer-down must not collapse the group before the pan recognizer gets
    // a chance to begin the drag.
    final pointer = await tester.startGesture(
      tester.getCenter(clip('b')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(controller.selection, {'a', 'b'});
    await pointer.cancel();
    await tester.pump();

    await dragClip('b');

    expect(controller.selection, {'a', 'b'});
    expect(doc.clipById('a')!.start, Rt.fromSeconds(1));
    expect(doc.clipById('b')!.start, Rt.fromSeconds(7));

    // A completed click still has the normal single-selection behavior.
    await tester.tap(clip('a'));
    await tester.pump();
    expect(controller.selection, {'a'});

    // Starting a drag from outside the selection replaces it and leaves the
    // previously selected clip in place.
    await dragClip('b');
    expect(controller.selection, {'b'});
    expect(doc.clipById('a')!.start, Rt.fromSeconds(1));
    expect(doc.clipById('b')!.start, Rt.fromSeconds(8));

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
