import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/state/editor_controller.dart';

import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/preview_renderer.dart';

Rt s(double value) => Rt.fromSeconds(value);

void main() {
  final frame = Rt(1, 30);

  test('parked preview renders the exact playhead', () {
    expect(
      computePreviewRenderTime(
        playhead: s(4),
        rangeStart: Rt.zero(),
        rangeEnd: s(10),
        frameDuration: frame,
        playing: false,
        rate: 1,
        renderMicros: 200000,
      ),
      s(4),
    );
  });

  test('playback target leads by measured latency within safe bounds', () {
    expect(
      computePreviewRenderTime(
        playhead: s(4),
        rangeStart: Rt.zero(),
        rangeEnd: s(10),
        frameDuration: frame,
        playing: true,
        rate: 1,
        renderMicros: 80000,
      ),
      s(4.08),
    );
    expect(
      computePreviewRenderTime(
        playhead: s(9.9),
        rangeStart: Rt.zero(),
        rangeEnd: s(10),
        frameDuration: frame,
        playing: true,
        rate: 1,
        renderMicros: 500000,
      ),
      s(10),
    );
  });

  test('reverse playback predicts backwards and clamps to range start', () {
    expect(
      computePreviewRenderTime(
        playhead: s(0.02),
        rangeStart: Rt.zero(),
        rangeEnd: s(10),
        frameDuration: frame,
        playing: true,
        rate: -1,
        renderMicros: 80000,
      ),
      Rt.zero(),
    );
  });

  test('stale seek, snapshot and playback frames are rejected', () {
    bool current({
      int requestRevision = 2,
      int currentRevision = 2,
      bool requestPlaying = false,
      bool playing = false,
      Rt? requested,
      Rt? playhead,
    }) =>
        isPreviewFrameCurrent(
          requestRevision: requestRevision,
          currentRevision: currentRevision,
          requestWasPlaying: requestPlaying,
          currentlyPlaying: playing,
          requested: requested ?? s(2),
          playhead: playhead ?? s(2),
          frameDuration: frame,
        );

    expect(current(), isTrue);
    expect(current(currentRevision: 3), isFalse);
    expect(current(playhead: s(3)), isFalse);
    expect(current(requestPlaying: true), isFalse);
    expect(
      current(requestPlaying: true, playing: true, playhead: s(2.05)),
      isTrue,
    );
    expect(
      current(requestPlaying: true, playing: true, playhead: s(2.2)),
      isFalse,
    );
  });

  group('preview render size', () {
    late Directory tmp;
    late EditorController c;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cc-preview-width');
      final doc = ProjectDoc.empty('P', width: 1920, height: 1080, fps: 30);
      c = EditorController(doc, path: '${tmp.path}/p.crazycut');
      c.setPreviewWidth(1920);
    });

    tearDown(() {
      c.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('parked monitor renders at the size it is displayed', () {
      expect(c.previewRenderWidth, 1920);
    });

    // Rendering size is a latency question, not only a sharpness one: a
    // full-resolution composite of a real project measures 30-110 ms, and at
    // that latency the image visibly trails the handles dragging it, which
    // reads as the gizmo being misaligned with its own clip.
    test('an open canvas gesture drops the render size, and restores it', () {
      c.beginGesture('Move image');
      c.previewLiveEdit();
      expect(c.previewRenderWidth, EditorController.maxLiveEditPreviewWidth);
      c.endGesture();
      expect(c.previewRenderWidth, 1920);
    });

    test('playback keeps its own cap', () {
      c.playing = true;
      expect(c.previewRenderWidth, EditorController.maxPlaybackPreviewWidth);
    });

    test('never renders larger than the monitor asked for', () {
      c.setPreviewWidth(640);
      c.beginGesture('Move image');
      c.previewLiveEdit();
      expect(c.previewRenderWidth, 640);
      c.endGesture();
    });
  });
}
