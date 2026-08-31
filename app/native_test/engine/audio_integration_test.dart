@Tags(['engine'])
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/core/math/rational.dart';

/// End-to-end audio through the FFI: the mixdown the monitor plays and the
/// export writes is the same call, so this covers both.
void main() {
  const fixture = '../fixtures/media/sample.mp4';
  final available = File(fixture).existsSync();

  ProjectDoc docWith({double volume = 1.0, double fadeInSeconds = 0}) {
    final doc = ProjectDoc.empty('Audio', width: 640, height: 360, fps: 30);
    doc.media.add(MediaAsset(
      id: 'a1',
      name: 'sample.mp4',
      path: File(fixture).absolute.path,
      type: 'video',
      duration: Rt.fromSeconds(10),
      hasAudio: true,
    ));
    final clip = Clip(
      id: 'c1',
      trackId: doc.videoTrack()!.id,
      mediaId: 'a1',
      label: 'clip',
      start: Rt.zero(),
      duration: Rt.fromSeconds(8),
      sourceIn: Rt.zero(),
    );
    clip.volume = volume;
    clip.fadeIn.duration = Rt.fromSeconds(fadeInSeconds);
    doc.clips.add(clip);
    return doc;
  }

  double rms(List<double> samples) {
    if (samples.isEmpty) return 0;
    var sum = 0.0;
    for (final s in samples) {
      sum += s * s;
    }
    return math.sqrt(sum / samples.length);
  }

  test('mixes the sequence to stereo 48 kHz', () {
    if (!available) {
      markTestSkipped('fixture media missing');
      return;
    }
    final engine = CrazyCutEngine.instance;
    final doc = docWith();
    engine.setProjectSnapshot(doc.encode(touchModified: false));
    final paths = {'a1': doc.media.first.path};

    final samples = engine.mixAudio(
      startSec: 1.0,
      seconds: 0.5,
      mediaPaths: paths,
    );
    // Interleaved stereo: two samples per frame.
    expect(samples.length, (0.5 * 48000).round() * 2);
  });

  test('clip gain scales the mix by the same factor', () {
    if (!available) {
      markTestSkipped('fixture media missing');
      return;
    }
    final engine = CrazyCutEngine.instance;
    final paths = {'a1': File(fixture).absolute.path};

    engine.setProjectSnapshot(docWith().encode(touchModified: false));
    final full = rms(engine.mixAudio(
      startSec: 1.0,
      seconds: 1.0,
      mediaPaths: paths,
    ).toList());

    if (full <= 0) {
      markTestSkipped('fixture has no audible audio');
      return;
    }

    engine.setProjectSnapshot(
        docWith(volume: 0.25).encode(touchModified: false));
    final quiet = rms(engine.mixAudio(
      startSec: 1.0,
      seconds: 1.0,
      mediaPaths: paths,
    ).toList());

    expect(quiet / full, closeTo(0.25, 0.02));
  });

  test('loudness analysis returns a plausible measurement', () {
    if (!available) {
      markTestSkipped('fixture media missing');
      return;
    }
    final engine = CrazyCutEngine.instance;
    engine.setProjectSnapshot(docWith().encode(touchModified: false));
    final report = engine.analyzeLoudness(
      startSec: 0,
      seconds: 8,
      mediaPaths: {'a1': File(fixture).absolute.path},
    );
    expect(report.lufs, lessThanOrEqualTo(0));
    expect(report.lufs, greaterThanOrEqualTo(-70));
    expect(report.truePeakDb, greaterThanOrEqualTo(report.peakDb - 0.01));
  });

  test('output device list is reachable', () {
    // No device on a CI box is a valid answer; the call must not throw.
    expect(() => CrazyCutEngine.instance.audioOutputDevices(), returnsNormally);
  });
}
