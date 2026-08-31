import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' hide Clip;
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/area_track.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/editor/presentation/widgets/area_track_overlay.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import '../../../support/temp_dir.dart';

/// The region tool driven the way a user drives it, rather than through the ops
/// it eventually calls.
///
/// Three things can only break here: the widget→sequence conversion (a drag in
/// a preview box that is not the document's size), the gated pan recognizer
/// (which must claim the pointers it wants and refuse the ones it does not),
/// and corner hit-testing on an already-solved quad.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const seqW = 1920, seqH = 1080;
  // Deliberately not the document size: the tool converts through
  // `doc.settings.width / box.width`, and a 1:1 box would hide a missing
  // conversion entirely.
  const boxW = 960.0, boxH = 540.0;
  const seqPerPx = seqW / boxW;

  late Directory tmp;
  setUpAll(() async => tmp = await Directory.systemTemp.createTemp('cc-drag'));
  tearDownAll(() => deleteTempDir(tmp));

  /// Records what the tool asked for instead of running a real solve, so the
  /// test is about the gesture and not about OpenCV.
  final requested = <({Quad region, Rt start})>[];

  (EditorController, Clip) harness() {
    requested.clear();
    final doc = ProjectDoc.empty('P', width: seqW, height: seqH, fps: 30);
    doc.media.add(
      MediaAsset(
        id: 'v',
        name: 'shot.mov',
        path: '/tmp/shot.mov',
        type: 'video',
        duration: Rt.fromSeconds(10),
        hasAudio: false,
        width: seqW,
        height: seqH,
      ),
    );
    final clip = Clip(
      id: 'c',
      trackId: doc.videoTrack()!.id,
      mediaId: 'v',
      label: 'Shot',
      start: Rt.zero(),
      duration: Rt.fromSeconds(5),
      sourceIn: Rt.zero(),
    );
    doc.clips.add(clip);
    final c = _RecordingController(doc, '${tmp.path}/drag.crazycut', requested);
    c.selection.add(clip.id);
    c.trackToolActive = true;
    addTearDown(c.dispose);
    return (c, clip);
  }

  Future<void> pump(WidgetTester tester, EditorController c) async {
    tester.view.physicalSize = const ui.Size(boxW, boxH);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // The editor screen wraps the monitor in a ListenableBuilder on the
    // controller; without the same here, arming the tool mid-test would not
    // rebuild and the widget would be testing a stale tree.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: boxW,
            height: boxH,
            child: ListenableBuilder(
              listenable: c,
              builder: (_, _) => AreaTrackOverlay(controller: c),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('dragging a box asks to track it in source pixels', (
    tester,
  ) async {
    final (c, _) = harness();
    await pump(tester, c);

    // A box from (100,60) to (300,180) in widget px.
    final origin = tester.getTopLeft(find.byType(AreaTrackOverlay));
    final gesture = await tester.startGesture(origin + const Offset(100, 60));
    await tester.pump();
    await gesture.moveTo(origin + const Offset(300, 180));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(requested, hasLength(1), reason: 'the drag should ask for a solve');
    final region = requested.single.region;
    // Source and sequence px coincide here, so the expected numbers are the
    // widget coordinates scaled by the preview factor — nothing else.
    expect(region[0], closeTo(100 * seqPerPx, 0.5));
    expect(region[1], closeTo(60 * seqPerPx, 0.5));
    expect(region[4], closeTo(300 * seqPerPx, 0.5));
    expect(region[5], closeTo(180 * seqPerPx, 0.5));
    // TL/TR/BR/BL order, so the second corner shares the top edge.
    expect(region[3], closeTo(region[1], 0.5));
  });

  testWidgets('a box dragged the other way is still TL/TR/BR/BL', (
    tester,
  ) async {
    final (c, _) = harness();
    await pump(tester, c);

    final origin = tester.getTopLeft(find.byType(AreaTrackOverlay));
    final gesture = await tester.startGesture(origin + const Offset(300, 180));
    await tester.pump();
    await gesture.moveTo(origin + const Offset(100, 60));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(requested, hasLength(1));
    final region = requested.single.region;
    expect(region[0], lessThan(region[4]), reason: 'left before right');
    expect(region[1], lessThan(region[5]), reason: 'top before bottom');
    expect(quadIsUsable(region), isTrue);
  });

  testWidgets('a click is not a region', (tester) async {
    // Without a minimum the tool would fire a solve on a sub-pixel box every
    // time the user clicked the monitor to focus it.
    final (c, _) = harness();
    await pump(tester, c);

    final origin = tester.getTopLeft(find.byType(AreaTrackOverlay));
    final gesture = await tester.startGesture(origin + const Offset(200, 120));
    await tester.pump();
    await gesture.moveTo(origin + const Offset(202, 121));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(requested, isEmpty);
  });

  testWidgets('the tool draws nothing while it is disarmed or playing', (
    tester,
  ) async {
    final (c, _) = harness();
    c.trackToolActive = false;
    await pump(tester, c);
    expect(find.byType(CustomPaint), findsNothing);

    // Armed again, it paints; and the pointer it claims is its own.
    c.trackToolActive = true;
    await tester.pump();
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('dragging a corner of a solved quad re-tracks from there', (
    tester,
  ) async {
    final (c, clip) = harness();
    // A solved region covering (400,300)-(1200,700) in source px.
    c.installTracker(
      Tracker(
        id: 't1',
        mediaId: 'v',
        sourceClipId: clip.id,
        startTime: Rt.zero(),
        endTime: Rt.fromSeconds(1),
        searchQuad: const [400, 300, 1200, 300, 1200, 700, 400, 700],
        fps: Rt(30, 1),
        path: const [400, 300, 1200, 300, 1200, 700, 400, 700],
        confidence: const [1.0],
      ),
    );
    // Committing an edit arms autosave's debounce and periodic timers, and the
    // binding fails the test if either is still pending when the tree goes
    // away. Nothing below writes to the document, so stopping them here is
    // enough — and is what the controller's own dispose does.
    c.autosave.dispose();
    await pump(tester, c);

    // The top-left corner sits at 400/seqPerPx, 300/seqPerPx in widget px.
    final origin = tester.getTopLeft(find.byType(AreaTrackOverlay));
    final corner = origin + const Offset(400 / seqPerPx, 300 / seqPerPx);
    final gesture = await tester.startGesture(corner);
    await tester.pump();
    await gesture.moveTo(corner + const Offset(20, 10));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(requested, hasLength(1), reason: 'the corner drag should re-track');
    final region = requested.single.region;
    // Only the dragged corner moved; the opposite one is where it was.
    expect(region[0], closeTo(400 + 20 * seqPerPx, 1.0));
    expect(region[1], closeTo(300 + 10 * seqPerPx, 1.0));
    expect(region[4], closeTo(1200, 1.0));
    expect(region[5], closeTo(700, 1.0));
  });
  testWidgets('the outline steps aside once something is pinned to it', (
    tester,
  ) async {
    // The outline is feedback of last resort: it is worth drawing while there
    // is nothing else showing the track, and is clutter over the result once
    // there is.
    final (c, clip) = harness();
    c.trackToolActive = false;
    c.installTracker(
      Tracker(
        id: 't1',
        mediaId: 'v',
        sourceClipId: clip.id,
        startTime: Rt.zero(),
        endTime: Rt.fromSeconds(1),
        searchQuad: const [200, 200, 600, 200, 600, 600, 200, 600],
        fps: Rt(1, 1),
        path: const [200, 200, 600, 200, 600, 600, 200, 600],
        confidence: const [1.0],
      ),
    );
    c.autosave.dispose();
    await pump(tester, c);

    // Nothing follows it yet, so it is drawn.
    expect(find.byType(CustomPaint), findsWidgets);

    // Pin the region's own clip to it — enough to make something follow it.
    c.pinClipToTracker(clip.id, 't1');
    c.autosave.dispose();
    await tester.pump();
    expect(
      find.byType(CustomPaint),
      findsNothing,
      reason: 'the pinned clip is the evidence now; the outline is clutter',
    );

    // Arming the tool brings it back, because then it is a control again.
    c.trackToolActive = true;
    await tester.pump();
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('the outline follows the playhead and survives leaving the clip', (
    tester,
  ) async {
    // Two bugs in one place. The outline never moved, because the playhead is
    // published on its own throttled notifier and this widget rebuilt only on
    // the controller's listeners. And scrubbing past the end of the clip threw
    // a null check *during layout* — LayoutBuilder's callback re-read the clip
    // under the playhead, which by then was gone — which also aborted the
    // rebuild and froze the outline where it was last painted.
    final (c, clip) = harness();
    c.trackToolActive = false;  // a readout, which is the state that was broken
    // A region sliding right by 100 px per sample, at 1 sample per second.
    c.installTracker(
      Tracker(
        id: 't1',
        mediaId: 'v',
        sourceClipId: clip.id,
        startTime: Rt.zero(),
        endTime: Rt.fromSeconds(3),
        searchQuad: const [200, 200, 600, 200, 600, 600, 200, 600],
        fps: Rt(1, 1),
        path: const [
          200, 200, 600, 200, 600, 600, 200, 600,
          300, 200, 700, 200, 700, 600, 300, 600,
          400, 200, 800, 200, 800, 600, 400, 600,
        ],
        confidence: const [1.0, 1.0, 1.0],
      ),
    );
    c.autosave.dispose();
    await pump(tester, c);

    // A single frame, deliberately. seekTo publishes on playheadNotifier
    // immediately but only notifies the controller's listeners on a 100 ms
    // throttle, so pumping past that would let the trailing notify do the work
    // and the assertion would pass whether or not this widget watches the
    // playhead at all. One frame is also what a scrub actually looks like.
    Future<void> seek(double seconds) async {
      c.seekTo(Rt.fromSeconds(seconds));
      await tester.pump();
    }

    List<double>? painted() {
      final paints = tester.widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(AreaTrackOverlay),
          matching: find.byType(CustomPaint),
        ),
      );
      for (final p in paints) {
        final painter = p.painter;
        if (painter == null) continue;
        final quad = (painter as dynamic).quad as List<double>?;
        if (quad != null) return quad;
      }
      return null;
    }

    await seek(0);
    final atStart = painted();
    expect(atStart, isNotNull, reason: 'the region should be drawn when solved');
    expect(atStart![0], closeTo(200, 1));

    await seek(2);
    final atTwo = painted();
    expect(atTwo, isNotNull);
    expect(
      atTwo![0],
      closeTo(400, 1),
      reason: 'the outline must follow the playhead, not sit where it was drawn',
    );

    // Past the end of the clip there is nothing under the playhead. This threw
    // during layout before; it must simply draw nothing.
    await seek(9);
    expect(tester.takeException(), isNull);
    // Drain the trailing notify the seeks armed, or the binding fails the test
    // on a pending timer.
    await tester.pump(const Duration(milliseconds: 200));
  });
}

/// Intercepts the solve so the gesture tests never spawn a worker. Everything
/// above it — hit testing, coordinate conversion, quad construction — is the
/// real code path.
class _RecordingController extends EditorController {
  _RecordingController(super.doc, String path, this._requested)
    : super(path: path);

  final List<({Quad region, Rt start})> _requested;

  @override
  Future<Tracker?> solveTrackedRegion({
    required String trackerId,
    required Clip clip,
    required MediaAsset asset,
    required Quad searchQuad,
    required Rt start,
    required Rt end,
  }) async {
    _requested.add((region: searchQuad, start: start));
    return null;
  }
}
