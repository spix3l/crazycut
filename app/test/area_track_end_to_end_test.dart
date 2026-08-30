import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/area_track.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';
import 'package:crazycut_app/state/tracking_service.dart';
import 'temp_dir.dart';

/// The whole feature, end to end, with nothing faked: the real worker solves a
/// clip whose motion is known, the result is installed and an overlay pinned to
/// it, and the frame is rendered through the same engine call the export worker
/// uses. What is asserted is the thing the feature promises — the overlay is
/// somewhere different at the end than at the start, and it moved *with* the
/// region rather than staying put.
///
/// Skips without the fixture (`tools/make-fixture.sh`) or the worker binary,
/// following the same rule the engine's golden tests use.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixture = File('${Directory.current.path}/../fixtures/media/track-pan.mp4');
  final worker = PlatformHelper.workerBinary();

  late Directory tmp;
  setUpAll(() async => tmp = await Directory.systemTemp.createTemp('cc-e2e'));
  tearDownAll(() => deleteTempDir(tmp));

  test('a tracked region carries a pinned overlay across the frame', () async {
    if (!fixture.existsSync()) {
      markTestSkipped('run tools/make-fixture.sh');
      return;
    }
    if (worker == null) {
      markTestSkipped('engine worker not built');
      return;
    }

    // The fixture is 640x360 and pans 2 px/frame; the sequence matches it so
    // source px and sequence px coincide.
    final doc = ProjectDoc.empty('E2E', width: 640, height: 360, fps: 30);
    doc.media.add(
      MediaAsset(
        id: 'pan',
        name: 'track-pan.mp4',
        path: fixture.path,
        type: 'video',
        duration: Rt.fromSeconds(3),
        hasAudio: false,
        width: 640,
        height: 360,
      ),
    );
    final tracks = doc.videoTracks;
    final source = Clip(
      id: 'source',
      trackId: tracks.first.id,
      mediaId: 'pan',
      label: 'Pan',
      start: Rt.zero(),
      duration: Rt.fromSeconds(2.5),
      sourceIn: Rt.zero(),
    );
    doc.clips.add(source);

    final c = EditorController(doc, path: '${tmp.path}/e2e.crazycut');

    // Track a textured box in the middle of the frame.
    final tracker = await c.trackRegion(
      source,
      quadFromRect(left: 240, top: 120, right: 400, bottom: 240),
      end: Rt.fromSeconds(2.4),
    );
    final job = TrackingService.instance.jobs.values.isEmpty
        ? null
        : TrackingService.instance.jobs.values.last;
    expect(
      tracker,
      isNotNull,
      reason: 'solve produced nothing: state=${job?.state} err=${job?.error}',
    );
    expect(tracker!.sampleCount, greaterThan(10));

    // Ground truth: the fixture pans 2 px per frame, so over ~2.4 s the region
    // travels a long way left and does not move vertically.
    final first = tracker.quadAt(Rt.zero());
    final last = tracker.quadAt(tracker.endTime);
    expect(first[0] - last[0], greaterThan(100), reason: 'region should travel');
    expect((last[1] - first[1]).abs(), lessThan(12), reason: 'and not vertically');

    // Pin an overlay to it. A flat magenta square keeps the render check
    // simple: the fixture contains no magenta, so finding the overlay in the
    // composited frame is a colour test.
    final overlayPath = '${tmp.path}/dot.png';
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 64, 64),
      ui.Paint()..color = const ui.Color(0xFFFF00FF),
    );
    final image = await recorder.endRecording().toImage(64, 64);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File(overlayPath).writeAsBytesSync(png!.buffer.asUint8List());
    doc.media.add(
      MediaAsset(
        id: 'dot',
        name: 'dot.png',
        path: overlayPath,
        type: 'image',
        duration: Rt.fromSeconds(3),
        hasAudio: false,
        width: 64,
        height: 64,
      ),
    );
    final overlay = Clip(
      id: 'overlay',
      trackId: tracks.length > 1 ? tracks[1].id : tracks.first.id,
      mediaId: 'dot',
      label: 'Dot',
      start: Rt.zero(),
      duration: Rt.fromSeconds(2.5),
      sourceIn: Rt.zero(),
    );
    doc.clips.add(overlay);
    c.pinClipToTracker(overlay.id, tracker.id);
    expect(
      c.doc.clipById('overlay')!.transform?.corners?.animated,
      isTrue,
      reason: 'a moving region must generate a moving pin',
    );

    // Render through the engine — the same call the export worker makes.
    final engine = CrazyCutEngine.instance;
    engine.setProjectSnapshot(c.doc.encode(touchModified: false));

    Rect? overlayBounds(double seconds) {
      final frame = engine.renderFrameRgba(
        time: Rt.fromSeconds(seconds),
        width: 640,
        height: 360,
        mediaPaths: {'pan': fixture.path, 'dot': overlayPath},
      );
      // The overlay is pure magenta; the fixture has no magenta in it.
      var left = 640, right = -1, top = 360, bottom = -1;
      for (var y = 0; y < 360; y += 1) {
        for (var x = 0; x < 640; x += 1) {
          final i = (y * 640 + x) * 4;
          final r = frame.rgba[i], g = frame.rgba[i + 1], b = frame.rgba[i + 2];
          if (r < 200 || g > 60 || b < 200) continue;
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
      }
      return right < 0
          ? null
          : Rect.fromLTRB(
              left.toDouble(),
              top.toDouble(),
              right.toDouble(),
              bottom.toDouble(),
            );
    }

    final atStart = overlayBounds(0.05);
    final atEnd = overlayBounds(2.3);
    expect(atStart, isNotNull, reason: 'the overlay did not render at all');
    expect(atEnd, isNotNull, reason: 'the overlay vanished by the end');

    // It adopted the region (TRK-19) and travelled with it.
    expect(atStart!.width, greaterThan(100));
    expect(
      atStart.center.dx - atEnd!.center.dx,
      greaterThan(100),
      reason: 'the overlay should have followed the pan left',
    );
    expect(
      (atEnd.center.dy - atStart.center.dy).abs(),
      lessThan(15),
      reason: 'and should not have drifted vertically',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
