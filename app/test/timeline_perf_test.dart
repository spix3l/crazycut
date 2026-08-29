import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

/// Perf budgets from `05-roadmap.md` §2 and TIM-22 / acceptance criterion 3.
/// These run on the CI machine, so the thresholds are deliberately generous
/// versus the interactive budget — they catch regressions, not hardware.
///
/// CI runners are shared machines, and the Windows ones run roughly twice as
/// slow as a dev machine with noisy neighbors, so the same budgets are scaled
/// up there; a real regression (an order of magnitude) still trips them.
final double budgetScale = Platform.isWindows
    ? 4.0
    : (Platform.environment.containsKey('CI') ? 2.0 : 1.0);
class Edits extends ChangeNotifier with TimelineEdits {
  Edits(this.doc);

  @override
  final ProjectDoc doc;

  @override
  Rt playhead = Rt.zero();

  @override
  double get fps => doc.settings.fpsValue;

  @override
  void markDirty() {}
}

Edits build500() {
  final doc = ProjectDoc.empty('Perf', fps: 30);
  doc.media.add(MediaAsset(
    id: 'm1',
    name: 'a.mov',
    path: '/tmp/a.mov',
    type: 'video',
    duration: Rt.fromSeconds(4000),
    hasAudio: true,
  ));
  final video = doc.videoTrack()!;
  final audio = doc.audioTrack()!;
  for (var i = 0; i < 250; i++) {
    for (final track in [video, audio]) {
      doc.clips.add(Clip(
        id: '${track.id}-$i',
        trackId: track.id,
        mediaId: 'm1',
        label: 'clip $i',
        start: Rt.fromSeconds(i * 4),
        duration: Rt.fromSeconds(4),
        sourceIn: Rt.fromSeconds(i * 4),
      ));
    }
  }
  return Edits(doc);
}

double p95(List<int> micros) {
  final sorted = [...micros]..sort();
  return sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)] / 1000;
}

void main() {
  test('500 clips: an edit and its undo commit well under 50 ms', () {
    final e = build500();
    expect(e.doc.clips, hasLength(500));

    final edits = <int>[];
    final undos = <int>[];
    for (var i = 0; i < 20; i++) {
      final clip = e.doc.clips[i * 7];
      final watch = Stopwatch()..start();
      e.moveClip(clip.id, start: clip.start.plus(Rt.fromSeconds(0.5)), snap: false);
      edits.add(watch.elapsedMicroseconds);
      watch.reset();
      e.undo();
      undos.add(watch.elapsedMicroseconds);
    }

    expect(p95(edits), lessThan(50 * budgetScale));
    expect(p95(undos), lessThan(50 * budgetScale));
  });

  test('500 clips: seeking and the frame lookup stay far under 100 ms', () {
    final e = build500();
    final video = e.doc.videoTrack()!.id;
    final samples = <int>[];
    for (var i = 0; i < 200; i++) {
      final watch = Stopwatch()..start();
      e.playhead = Rt.fromSeconds(i * 5.0);
      final hit = e.doc
          .clipsOn(video)
          .where((c) => e.playhead >= c.start && e.playhead < c.end)
          .firstOrNull;
      samples.add(watch.elapsedMicroseconds);
      expect(hit == null || hit.trackId == video, isTrue);
    }
    expect(p95(samples), lessThan(100 * budgetScale));
  });

  test('500 clips: one frame of lane virtualization costs a fraction of 16 ms',
      () {
    final e = build500();
    const viewportSeconds = 30.0;
    final frames = <int>[];

    for (var i = 0; i < 120; i++) {
      final from = i * 2.0;
      final to = from + viewportSeconds;
      final watch = Stopwatch()..start();
      var drawn = 0;
      for (final track in e.laneOrder) {
        drawn += e.doc
            .clipsOn(track.id)
            .where((c) => c.end.seconds >= from && c.start.seconds <= to)
            .length;
      }
      frames.add(watch.elapsedMicroseconds);
      // Virtualization is doing its job: a 30 s window never draws the lot.
      expect(drawn, lessThan(40));
    }

    expect(p95(frames), lessThan(16 * budgetScale));
  });

  test('500 clips: select-all then a group move stays interactive', () {
    final e = build500();
    e.selectAll();

    final watch = Stopwatch()..start();
    e.beginDrag(EditGesture.move, e.doc.clips.first.id);
    for (var i = 1; i <= 10; i++) {
      e.updateDrag(i * 0.1, snap: false);
    }
    e.endGesture();
    final elapsedMs = watch.elapsedMicroseconds / 1000;

    expect(e.doc.clips.first.start, Rt.fromSeconds(1));
    // Ten drag updates over 500 clips: a whole gesture inside a few frames.
    expect(elapsedMs, lessThan(500 * budgetScale));
  });
}
