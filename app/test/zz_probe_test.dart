@Tags(['perf'])
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/preview_renderer.dart';

void main() {
  const fixture = '../fixtures/media/long.mp4';

  test('probe multi-clip playback', () async {
    final path = File(fixture).absolute.path;
    final doc = ProjectDoc.empty('P', width: 1280, height: 720, fps: 30);
    doc.media.add(MediaAsset(
      id: 'a', name: 's.mp4', path: path, type: 'video',
      duration: Rt.fromSeconds(600), hasAudio: true,
    ));
    final track = doc.videoTrack()!.id;
    // Three cuts, each pulling from a different part of the source, so a clip
    // that fails to render is obvious rather than looking like its neighbour.
    for (var i = 0; i < 3; i++) {
      doc.clips.add(Clip(
        id: 'c$i', trackId: track, mediaId: 'a', label: 'c$i',
        start: Rt.fromSeconds(i * 2.0),
        duration: Rt.fromSeconds(2),
        sourceIn: Rt.fromSeconds([30.0, 400.0, 120.0][i]),
      ));
    }

    final r = await PreviewRenderer.spawn();
    addTearDown(r.dispose);
    r.setSnapshot(doc.encode(touchModified: false));

    const w = 960, h = 540;
    String sig(List<int> rgba) {
      var sum = 0;
      for (var i = 0; i < rgba.length; i += 4001) {
        sum = (sum * 31 + rgba[i]) & 0xFFFFF;
      }
      return sum.toRadixString(16);
    }

    for (var f = 0; f < 180; f += 6) {
      final t = Rt.fromSeconds(f / 30);
      final sw = Stopwatch()..start();
      final frame = await r.render(
        time: t, width: w, height: h, mediaPaths: {'a': path});
      sw.stop();
      var nonBlack = 0;
      for (var i = 0; i < frame.rgba.length; i += 4) {
        if (frame.rgba[i] > 8) nonBlack++;
      }
      // ignore: avoid_print
      print('t=${(f / 30).toStringAsFixed(2)} clip=${f ~/ 60} '
          '${sw.elapsedMilliseconds}ms sig=${sig(frame.rgba)} '
          'lit=${(nonBlack * 100 / (w * h)).toStringAsFixed(0)}%');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
