import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import 'package:crazycut_app/modules/editor/infrastructure/preview_renderer.dart';
import '../../support/temp_dir.dart';

/// What made the preview feel heavy was never the composite — the engine turns
/// one out in ~3 ms at playback resolution (`preview_perf_test.dart`). It was
/// the blast radius: every playhead step and every composited frame went out
/// through `notifyListeners`, rebuilding the media pool, the inspector and all
/// 500 clips of the timeline 30-60 times a second.
///
/// These tests pin the narrow channels that carry transport-rate state, so a
/// future edit cannot quietly route it back through the whole editor.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cc-preview-pipeline');
  });
  tearDown(() => deleteTempDir(tmp));

  EditorController controller() {
    final doc = ProjectDoc.empty('P', width: 1280, height: 720, fps: 30);
    final c = EditorController(doc, path: '${tmp.path}/p.ccproj');
    addTearDown(c.close);
    return c;
  }

  test('moving the playhead publishes on its own channel, not to the editor',
      () {
    final c = controller();
    var editorRebuilds = 0;
    final steps = <Rt>[];
    c.addListener(() => editorRebuilds++);
    c.playheadNotifier.addListener(() => steps.add(c.playhead));

    for (var i = 1; i <= 30; i++) {
      c.playhead = Rt.fromSeconds(i / 30);
    }

    expect(steps, hasLength(30), reason: 'the cursor follows every step');
    expect(editorRebuilds, 0, reason: 'nothing else is rebuilt');
    expect(c.playhead, Rt.fromSeconds(1));
  });

  test('a repeated playhead value is not republished', () {
    final c = controller();
    var steps = 0;
    c.playheadNotifier.addListener(() => steps++);
    c.playhead = Rt.fromSeconds(2);
    c.playhead = Rt.fromSeconds(2);
    expect(steps, 1);
  });

  test('a composited frame reaches the monitor without an editor rebuild', () {
    final c = controller();
    var editorRebuilds = 0;
    var monitorRepaints = 0;
    c.addListener(() => editorRebuilds++);
    c.previewImage.addListener(() => monitorRepaints++);

    c.previewImage.value = PreviewFrame(
      time: Rt.fromSeconds(1),
      width: 4,
      height: 2,
      rgba: Uint8List(4 * 2 * 4),
    );

    expect(monitorRepaints, 1);
    expect(editorRebuilds, 0);
    // The convenience views stay in step with the channel.
    expect(c.previewFrameSize, (4, 2));
    expect(c.previewFrameTime, 1.0);
    expect(c.previewFrame, isNotNull);
  });

  /// The complaint this guards against is "sometimes doesn't play clips": a
  /// cut where the monitor stops updating while audio and the playhead carry
  /// on. Every mechanism that can cause it — a cold seek at a clip boundary, a
  /// source range the decoder has to reposition into, a frame arriving later
  /// than the transport expected — lives on this path, so it is walked with
  /// real media rather than mocked.
  test('every clip across a cut renders, and its image advances', () async {
    const fixture = '../fixtures/media/sample.mp4';
    if (!File(fixture).existsSync()) {
      markTestSkipped('fixture media missing');
      return;
    }
    final path = File(fixture).absolute.path;

    final doc = ProjectDoc.empty('P', width: 1280, height: 720, fps: 30);
    doc.media.add(MediaAsset(
      id: 'a',
      name: 'sample.mp4',
      path: path,
      type: 'video',
      duration: Rt.fromSeconds(10),
      hasAudio: true,
    ));
    final track = doc.videoTrack()!.id;
    // Each cut pulls from a different part of the source — and not in source
    // order, so a clip the decoder failed to reposition into shows up as its
    // neighbour's pixels rather than blending in.
    const sourceIns = [6.0, 0.0, 3.0];
    for (var i = 0; i < sourceIns.length; i++) {
      doc.clips.add(Clip(
        id: 'c$i',
        trackId: track,
        mediaId: 'a',
        label: 'c$i',
        start: Rt.fromSeconds(i * 2.0),
        duration: Rt.fromSeconds(2),
        sourceIn: Rt.fromSeconds(sourceIns[i]),
      ));
    }

    final renderer = await PreviewRenderer.spawn();
    addTearDown(renderer.dispose);
    renderer.setSnapshot(doc.encode(touchModified: false));

    int signature(Uint8List rgba) {
      var hash = 0;
      for (var i = 0; i < rgba.length; i += 4001) {
        hash = (hash * 31 + rgba[i]) & 0xFFFFF;
      }
      return hash;
    }

    final perClip = <int, List<int>>{};
    for (var f = 0; f < 180; f += 5) {
      final frame = await renderer.render(
        time: Rt.fromSeconds(f / 30),
        width: 640,
        height: 360,
        mediaPaths: {'a': path},
      );
      (perClip[f ~/ 60] ??= []).add(signature(frame.rgba));
    }

    expect(perClip.keys, hasLength(3), reason: 'all three clips were sampled');
    for (final entry in perClip.entries) {
      expect(
        entry.value.toSet().length,
        greaterThan(1),
        reason: 'clip ${entry.key} froze on one frame instead of playing',
      );
    }
    // A clip that silently reused the previous decoder position would repeat
    // its neighbour's pixels at the cut.
    expect(perClip[0]!.first, isNot(perClip[1]!.first));
    expect(perClip[1]!.first, isNot(perClip[2]!.first));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('meter ballistics ride their own channel', () {
    final c = controller();
    var editorRebuilds = 0;
    var meterRepaints = 0;
    c.addListener(() => editorRebuilds++);
    c.audioLevelsNotifier.addListener(() => meterRepaints++);

    c.audioLevels = (0.4, 0.5);
    c.audioLevels = (0.6, 0.7);

    expect(meterRepaints, 2);
    expect(editorRebuilds, 0);
    expect(c.audioLevels, (0.6, 0.7));
  });
}
