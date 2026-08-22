@Tags(['perf'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';
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
    const previewWidth = EditorController.maxPlaybackPreviewWidth;
    const previewHeight = previewWidth * 9 ~/ 16;
    await renderer.render(
      time: Rt.zero(),
      width: previewWidth,
      height: previewHeight,
      mediaPaths: paths,
    );

    final sw = Stopwatch()..start();
    for (var i = 1; i <= frames; i++) {
      final frame = await renderer.render(
        time: Rt.fromMicros(frameDuration.micros * i),
        width: previewWidth,
        height: previewHeight,
        mediaPaths: paths,
      );
      expect(frame.width, previewWidth);
      expect(frame.rgba.length, previewWidth * previewHeight * 4);
    }
    sw.stop();

    final msPerFrame = sw.elapsedMilliseconds / frames;
    // ignore: avoid_print
    print('preview: ${msPerFrame.toStringAsFixed(2)} ms/frame '
        '(${(1000 / msPerFrame).toStringAsFixed(1)} fps) '
        'at ${previewWidth}x$previewHeight');
    expect(msPerFrame, lessThan(33.3),
        reason: 'preview must composite 30 fps material in realtime');

    // The program monitor commonly blurs a background video underneath an
    // image/title. Blur cost must stay linear in radius so that workflow does
    // not make the monitor trail the timeline by seconds.
    doc.clips.single.effects.add({
      'id': 'blur-1',
      'type': 'gaussianBlur',
      'enabled': true,
      'params': {
        'radius': {'static': 40.0},
      },
    });
    renderer.setSnapshot(doc.encode(touchModified: false));
    await renderer.render(
      time: Rt.zero(),
      width: previewWidth,
      height: previewHeight,
      mediaPaths: paths,
    );

    const blurredFrames = 30;
    final blurWatch = Stopwatch()..start();
    for (var i = 1; i <= blurredFrames; i++) {
      await renderer.render(
        time: Rt.fromMicros(frameDuration.micros * i),
        width: previewWidth,
        height: previewHeight,
        mediaPaths: paths,
      );
    }
    blurWatch.stop();
    final blurMsPerFrame = blurWatch.elapsedMilliseconds / blurredFrames;
    // ignore: avoid_print
    print('blurred preview: ${blurMsPerFrame.toStringAsFixed(2)} ms/frame '
        '(${(1000 / blurMsPerFrame).toStringAsFixed(1)} fps)');
    expect(blurMsPerFrame, lessThan(33.3),
        reason: 'blurred preview must remain realtime at playback quality');
  }, timeout: const Timeout(Duration(minutes: 2)));

  /// Compositing is only part of a preview frame's life. After the isolate is
  /// done the UI thread still has to materialize the buffer, upload it as a
  /// texture and repaint. With a single request outstanding the isolate idles
  /// through all of that, so throughput was bounded by round-trip latency
  /// rather than by render cost. `EditorController` keeps two requests in
  /// flight; this measures what that buys.
  test('a second in-flight request hides the round trip', () async {
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
    const previewWidth = EditorController.maxPlaybackPreviewWidth;
    const previewHeight = previewWidth * 9 ~/ 16;
    final frameDuration = Rt.fromSeconds(1 / 30);

    // Stands in for the per-frame work the UI thread does once a composite
    // lands. Any wait works: the point is that the isolate should not be
    // sitting on its hands for it.
    const uiWork = Duration(milliseconds: 8);
    Future<PreviewFrame> request(int i) => renderer.render(
          time: Rt.fromMicros(frameDuration.micros * i),
          width: previewWidth,
          height: previewHeight,
          mediaPaths: paths,
        );

    await request(0);
    const frames = 40;

    final serial = Stopwatch()..start();
    for (var i = 1; i <= frames; i++) {
      await request(i);
      await Future<void>.delayed(uiWork);
    }
    serial.stop();

    final pipelined = Stopwatch()..start();
    var next = await request(1);
    for (var i = 2; i <= frames + 1; i++) {
      final ahead = request(i);
      expect(next.rgba.length, previewWidth * previewHeight * 4);
      await Future<void>.delayed(uiWork);
      next = await ahead;
    }
    pipelined.stop();

    final serialMs = serial.elapsedMilliseconds / frames;
    final pipelinedMs = pipelined.elapsedMilliseconds / frames;
    // ignore: avoid_print
    print('serial: ${serialMs.toStringAsFixed(2)} ms/frame, '
        'pipelined: ${pipelinedMs.toStringAsFixed(2)} ms/frame');
    expect(pipelinedMs, lessThan(serialMs * 0.9),
        reason: 'a second slot must overlap compositing with the round trip');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
