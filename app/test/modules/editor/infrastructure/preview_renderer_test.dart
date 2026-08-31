import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';

import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/infrastructure/preview_renderer.dart';
import '../../../support/temp_dir.dart';

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

  test('stale snapshots and transport transitions are rejected', () {
    bool current({
      int requestRevision = 2,
      int currentRevision = 2,
      bool requestPlaying = false,
      bool playing = false,
      int requestSeq = 7,
      int shownSeq = 6,
    }) =>
        isPreviewFrameCurrent(
          requestRevision: requestRevision,
          currentRevision: currentRevision,
          requestWasPlaying: requestPlaying,
          currentlyPlaying: playing,
          requestSeq: requestSeq,
          shownSeq: shownSeq,
        );

    expect(current(), isTrue);
    // Rendered from a document, size or transport mode that no longer applies.
    expect(current(currentRevision: 3), isFalse);
    expect(current(requestPlaying: true), isFalse);
    // A request that an already-shown one overtook stays off the monitor.
    expect(current(requestSeq: 5, shownSeq: 6), isFalse);
    expect(current(requestSeq: 6, shownSeq: 6), isFalse);
  });

  /// Recency used to be judged by how close the rendered time landed to the
  /// playhead. A clip that composites slower than the lead can compensate for
  /// then missed the window by a fixed margin on *every* frame, so the monitor
  /// showed nothing at all while audio and the playhead kept running — the
  /// picture froze on exactly the heavy clips it most needed to show.
  ///
  /// This replays the loop's arithmetic at a range of render costs. The rule
  /// is that expensive frames arrive late, never that they stop arriving.
  test('a clip slower than the lead estimate still reaches the monitor', () {
    int framesShown({required double renderMs, int frames = 60}) {
      var playheadMicros = 0;
      var renderMicros = frame.micros;
      var shown = 0;
      var seq = 0;
      var shownSeq = 0;
      final latency = (renderMs * 1000).round();
      for (var i = 0; i < frames; i++) {
        final requested = computePreviewRenderTime(
          playhead: Rt.fromMicros(playheadMicros),
          rangeStart: Rt.zero(),
          rangeEnd: s(600),
          frameDuration: frame,
          playing: true,
          rate: 1,
          renderMicros: renderMicros,
        );
        expect(requested >= Rt.fromMicros(playheadMicros), isTrue);
        // The composite takes `latency`; the playhead runs on a wall clock and
        // has moved on by the time the frame lands.
        playheadMicros += latency;
        renderMicros = (renderMicros * 0.75 + latency * 0.25).round();
        final mine = ++seq;
        if (isPreviewFrameCurrent(
          requestRevision: 1,
          currentRevision: 1,
          requestWasPlaying: true,
          currentlyPlaying: true,
          requestSeq: mine,
          shownSeq: shownSeq,
        )) {
          shownSeq = mine;
          shown++;
        }
      }
      return shown;
    }

    // Comfortably realtime, and far past it: neither may blank the monitor.
    for (final renderMs in [3.0, 40.0, 150.0, 316.0, 400.0, 800.0, 2000.0]) {
      expect(framesShown(renderMs: renderMs), 60,
          reason: 'a ${renderMs.toStringAsFixed(0)} ms frame must still show');
    }
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
      deleteTempDir(tmp);
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
