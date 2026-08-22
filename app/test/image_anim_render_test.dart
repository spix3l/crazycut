import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';

import 'image_anim_test.dart' show Edits, s;

/// End-to-end proof that a generated image animation reaches actual pixels.
///
/// The Dart side only writes keyframes and effect instances; everything that
/// makes them visible lives in the C++ compositor. Rendering through the real
/// engine is what shows the two agree — and because export drives the same
/// `renderFrame`, it is also the export-parity check.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String imagePath;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('cc-image-anim');
    imagePath = '${tmp.path}/swatch.png';
    // Two flat opaque halves: opaque everywhere, so any transparency or crop
    // in the output is the animation's doing; and with one hard internal edge,
    // so a blur has something to soften.
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 128, 256),
      ui.Paint()..color = const ui.Color(0xFFFF0000),
    );
    canvas.drawRect(
      const ui.Rect.fromLTWH(128, 0, 128, 256),
      ui.Paint()..color = const ui.Color(0xFF0000FF),
    );
    final image = await recorder.endRecording().toImage(256, 256);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File(imagePath).writeAsBytesSync(png!.buffer.asUint8List());
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  (Edits, Clip) project() {
    // 16:9 around a square source, so a fitted image leaves black bars: the
    // lit-pixel fraction can then actually move when the image grows or blurs.
    final doc = ProjectDoc.empty('Render', width: 160, height: 90, fps: 30);
    doc.media.add(
      MediaAsset(
        id: 'img',
        name: 'swatch.png',
        path: imagePath,
        type: 'image',
        duration: s(4),
        hasAudio: false,
        width: 256,
        height: 256,
      ),
    );
    final clip = Clip(
      id: 'c1',
      trackId: doc.videoTrack()!.id,
      mediaId: 'img',
      label: 'swatch',
      start: Rt.zero(),
      duration: s(4),
      sourceIn: Rt.zero(),
    );
    doc.clips.add(clip);
    return (Edits(doc), clip);
  }

  /// One rendered frame, reduced to the three things the presets move.
  ///
  /// [brightness] is the red half's level, so a fade shows up in it; [covered]
  /// is the fraction of the canvas that is not black, so a scale, a pan or a
  /// wipe shows up in it; [seamWidth] counts the pixels straddling the red/blue
  /// edge, so a blur shows up in it.
  ({int brightness, double covered, int seamWidth}) sample(
    Edits e,
    double seconds,
  ) {
    final engine = CrazyCutEngine.instance;
    engine.setProjectSnapshot(e.doc.encode(touchModified: false));
    final frame = engine.renderFrameRgba(
      time: s(seconds),
      width: 160,
      height: 90,
      mediaPaths: {'img': imagePath},
    );
    final rgba = frame.rgba;
    var lit = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      if (rgba[i] > 8 || rgba[i + 1] > 8 || rgba[i + 2] > 8) lit += 1;
    }
    final row = [
      for (var x = 0; x < 160; x += 1) rgba[((90 ~/ 2) * 160 + x) * 4],
    ];
    final peak = row.reduce((a, b) => a > b ? a : b);
    return (
      brightness: peak,
      covered: lit / (rgba.length / 4),
      // Relative to this frame's own peak, so a fade does not read as a blur.
      seamWidth: row
          .where((v) => v > peak * 0.15 && v < peak * 0.85)
          .length,
    );
  }

  bool available() => File(imagePath).existsSync();

  test('a fade-in darkens the head of the clip and clears by its end', () {
    if (!available()) return markTestSkipped('could not write the fixture');
    final (e, clip) = project();
    e.setImageEntryExit(clip.id, appear: 'fade', seconds: 1);

    final start = sample(e, 0.0).brightness;
    final mid = sample(e, 0.5).brightness;
    final settled = sample(e, 2.0).brightness;

    expect(start, lessThan(mid));
    expect(mid, lessThan(settled));
    expect(settled, greaterThan(200), reason: 'fully opaque red once settled');
  });

  test('a fade-out darkens the tail', () {
    if (!available()) return markTestSkipped('could not write the fixture');
    final (e, clip) = project();
    e.setImageEntryExit(clip.id, disappear: 'fade', seconds: 1);

    expect(sample(e, 2.0).brightness, greaterThan(sample(e, 3.5).brightness));
  });

  test('a pop starts smaller than it settles', () {
    if (!available()) return markTestSkipped('could not write the fixture');
    final (e, clip) = project();
    e.setImageEntryExit(clip.id, appear: 'pop', seconds: 1);

    expect(sample(e, 0.05).covered, lessThan(sample(e, 2.0).covered));
  });

  test('a wipe uncovers the image across its window', () {
    if (!available()) return markTestSkipped('could not write the fixture');
    final (e, clip) = project();
    e.setImageEntryExit(clip.id, appear: 'wipeRight', seconds: 1);

    final atStart = sample(e, 0.0).covered;
    final halfway = sample(e, 0.5).covered;
    final settled = sample(e, 2.0).covered;

    expect(atStart, lessThan(0.01), reason: 'fully cropped at the head');
    expect(halfway, greaterThan(atStart));
    expect(settled, greaterThan(halfway));
  });

  test('a blur softens the image at the head and resolves sharp', () {
    if (!available()) return markTestSkipped('could not write the fixture');
    final (e, clip) = project();
    e.setImageEntryExit(clip.id, appear: 'blur', seconds: 1);

    // The hard red/blue edge is smeared across several pixels at the head and
    // back to a one-pixel step once the radius has keyed to zero.
    expect(sample(e, 0.05).seamWidth, greaterThan(sample(e, 2.0).seamWidth));
    expect(sample(e, 2.0).seamWidth, lessThanOrEqualTo(1));
  });

  test('a Ken Burns move still renders alongside an entry animation', () {
    if (!available()) return markTestSkipped('could not write the fixture');
    final (e, clip) = project();
    e.applyImagePreset(clip.id, 'zoomIn');
    e.setImageEntryExit(clip.id, appear: 'fade', seconds: 0.5);

    // Fully faded in by 0.5s, then the zoom keeps growing the covered area.
    expect(sample(e, 3.9).covered, greaterThan(sample(e, 1.0).covered));
  });
}
