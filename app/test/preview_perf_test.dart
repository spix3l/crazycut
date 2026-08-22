@Tags(['perf'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/preview_renderer.dart';

/// Measures how fast the preview pipeline can composite sequential frames.
///
/// Realtime preview is a milestone exit criterion (roadmap M0/M2), and the two
/// things that break it — reopening media per frame and rendering on the UI
/// isolate — are both invisible in unit tests. This renders through the real
/// isolate + engine so a regression shows up as a number.
void main() {
  const fixture = '../fixtures/media/sample.mp4';

  test('composites sequential preview frames faster than realtime', () async {
    if (!File(fixture).existsSync()) {
      markTestSkipped('fixture media missing');
      return;
    }

    final doc = ProjectDoc.empty('Perf', width: 1280, height: 720, fps: 30);
    doc.media.add(MediaAsset(
      id: 'asset-1',
      name: 'sample.mp4',
      path: File(fixture).absolute.path,
      type: 'video',
      duration: Rt.fromSeconds(20),
      hasAudio: true,
    ));
    doc.clips.add(Clip(
      id: 'clip-1',
      trackId: doc.videoTrack()!.id,
      mediaId: 'asset-1',
      label: 'clip',
      start: Rt.zero(),
      duration: Rt.fromSeconds(10),
      sourceIn: Rt.zero(),
    ));

    final renderer = await PreviewRenderer.spawn();
    addTearDown(renderer.dispose);
    renderer.setSnapshot(doc.encode(touchModified: false));

    final paths = {'asset-1': File(fixture).absolute.path};
    const frames = 60;
    final frameDuration = Rt.fromSeconds(1 / 30);

    // Warm the decoder and scaler before timing.
    await renderer.render(
      time: Rt.zero(),
      width: 1280,
      height: 720,
      mediaPaths: paths,
    );

    final sw = Stopwatch()..start();
    for (var i = 1; i <= frames; i++) {
      final frame = await renderer.render(
        time: Rt.fromMicros(frameDuration.micros * i),
        width: 1280,
        height: 720,
        mediaPaths: paths,
      );
      expect(frame.width, 1280);
      expect(frame.rgba.length, 1280 * 720 * 4);
    }
    sw.stop();

    final msPerFrame = sw.elapsedMilliseconds / frames;
    // ignore: avoid_print
    print('preview: ${msPerFrame.toStringAsFixed(2)} ms/frame '
        '(${(1000 / msPerFrame).toStringAsFixed(1)} fps) at 1280x720');
    expect(msPerFrame, lessThan(33.3),
        reason: 'preview must composite 30 fps material in realtime');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
