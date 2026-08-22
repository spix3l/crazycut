import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/editor_controller.dart';
import 'package:crazycut_app/state/preview_renderer.dart';

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
  tearDown(() => tmp.deleteSync(recursive: true));

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
