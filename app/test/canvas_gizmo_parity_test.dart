import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/clip_transform.dart';
import 'package:crazycut_app/data/param_value.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/canvas_geometry.dart';

/// The on-canvas gizmo draws handles on a rect it computes in Dart, over an
/// image the C++ compositor rasterises. Those are two independent
/// implementations of the same geometry, and a drift between them puts the
/// handles somewhere the image is not.
///
/// So: render through the real engine, find where the pixels actually landed,
/// and compare with what `layerRectInSequence` predicted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const seqW = 640;
  const seqH = 360;

  late Directory tmp;

  setUpAll(() async => tmp = await Directory.systemTemp.createTemp('cc-gizmo'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  /// A flat white rectangle, so the drawn bounding box is unambiguous.
  Future<String> source(int width, int height) async {
    final path = '${tmp.path}/src_${width}x$height.png';
    if (File(path).existsSync()) return path;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final image = await recorder.endRecording().toImage(width, height);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path).writeAsBytesSync(png!.buffer.asUint8List());
    return path;
  }

  /// Bounding box of the non-black pixels the engine actually drew, reported
  /// in *document* pixels so it can be compared with the gizmo's rect.
  ///
  /// [renderWidth] is the canvas the frame is rasterised into, which for a
  /// preview is routinely smaller than the document — the monitor renders at
  /// widget resolution and caps at 960 during playback.
  ui.Rect? drawnRect({
    required String path,
    required int srcW,
    required int srcH,
    required String framing,
    required double x,
    required double y,
    required double scale,
    int renderWidth = seqW,
  }) {
    final doc = ProjectDoc.empty('P', width: seqW, height: seqH, fps: 30);
    doc.media.add(
      MediaAsset(
        id: 'i',
        name: 'src.png',
        path: path,
        type: 'image',
        duration: Rt.fromSeconds(4),
        hasAudio: false,
        width: srcW,
        height: srcH,
      ),
    );
    doc.clips.add(
      Clip(
        id: 'c',
        trackId: doc.videoTrack()!.id,
        mediaId: 'i',
        label: 'src',
        start: Rt.zero(),
        duration: Rt.fromSeconds(4),
        sourceIn: Rt.zero(),
        transform: ClipTransform(
          x: ParamValue.staticNum(x),
          y: ParamValue.staticNum(y),
          scale: ParamValue.staticNum(scale),
          framing: framing,
        ),
      ),
    );
    final renderHeight = (renderWidth * seqH / seqW).round();
    final engine = CrazyCutEngine.instance;
    engine.setProjectSnapshot(doc.encode(touchModified: false));
    final frame = engine.renderFrameRgba(
      time: Rt.fromSeconds(1),
      width: renderWidth,
      height: renderHeight,
      mediaPaths: {'i': path},
    );
    var left = renderWidth, top = renderHeight, right = -1, bottom = -1;
    for (var py = 0; py < renderHeight; py += 1) {
      for (var px = 0; px < renderWidth; px += 1) {
        if (frame.rgba[(py * renderWidth + px) * 4] <= 40) continue;
        if (px < left) left = px;
        if (px > right) right = px;
        if (py < top) top = py;
        if (py > bottom) bottom = py;
      }
    }
    if (right < 0) return null;
    // Pixel indices are inclusive; the predicted rect's edges are exclusive.
    final kx = seqW / renderWidth;
    final ky = seqH / renderHeight;
    return ui.Rect.fromLTRB(
      left * kx,
      top * ky,
      (right + 1) * kx,
      (bottom + 1) * ky,
    );
  }

  Future<void> expectParity({
    required int srcW,
    required int srcH,
    String framing = 'fit',
    double x = 0,
    double y = 0,
    double scale = 100,
    int renderWidth = seqW,
  }) async {
    final path = await source(srcW, srcH);
    final drawn = drawnRect(
      path: path,
      srcW: srcW,
      srcH: srcH,
      framing: framing,
      x: x,
      y: y,
      scale: scale,
      renderWidth: renderWidth,
    );
    final predicted = layerRectInSequence(
      seqW: seqW,
      seqH: seqH,
      srcW: srcW,
      srcH: srcH,
      framing: framing,
      x: x,
      y: y,
      scalePercent: scale,
    );
    expect(drawn, isNotNull, reason: 'the engine drew nothing');
    final reason =
        '${srcW}x$srcH $framing x=$x y=$y scale=$scale render=$renderWidth';
    // Slack of one document pixel per render pixel: the compositor rounds its
    // destination rect to whole pixels, and off-canvas edges are clipped.
    final slack = seqW / renderWidth;
    expect(drawn!.left, closeTo(predicted.left.clamp(0, seqW), slack),
        reason: reason);
    expect(drawn.top, closeTo(predicted.top.clamp(0, seqH), slack),
        reason: reason);
    expect(drawn.right, closeTo(predicted.right.clamp(0, seqW), slack),
        reason: reason);
    expect(drawn.bottom, closeTo(predicted.bottom.clamp(0, seqH), slack),
        reason: reason);
  }

  test('a fitted image lands where the gizmo predicts', () async {
    await expectParity(srcW: 400, srcH: 400);
    await expectParity(srcW: 800, srcH: 600);
    await expectParity(srcW: 300, srcH: 900);
  });

  test('scaling down keeps the rects together', () async {
    await expectParity(srcW: 400, srcH: 400, scale: 60);
    await expectParity(srcW: 800, srcH: 600, scale: 25);
  });

  test('an off-centre image lands where the gizmo predicts', () async {
    await expectParity(srcW: 400, srcH: 400, x: 80, y: -40, scale: 60);
    await expectParity(srcW: 300, srcH: 900, x: -120, y: 30, scale: 40);
  });

  test('fill and stretch framing agree too', () async {
    await expectParity(srcW: 400, srcH: 400, framing: 'fill', scale: 50);
    await expectParity(srcW: 800, srcH: 600, framing: 'stretch', scale: 70);
  });

  // The monitor renders at widget resolution, capped at 960 wide during
  // playback, so the preview canvas is routinely a fraction of the document.
  // Transform x/y are authored in document pixels, and until the compositor
  // brought them into render space a half-size preview put the image twice as
  // far from centre as its handles — the drawn image slid out of its own box
  // as soon as it was moved off centre.
  test('a smaller preview canvas puts the image in the same place', () async {
    for (final renderWidth in [seqW, seqW ~/ 2, 200]) {
      await expectParity(
        srcW: 400,
        srcH: 400,
        x: 120,
        y: -60,
        scale: 50,
        renderWidth: renderWidth,
      );
      await expectParity(
        srcW: 800,
        srcH: 600,
        x: -90,
        y: 40,
        scale: 70,
        renderWidth: renderWidth,
      );
    }
  });

  test('a drag resolved by GizmoDrag pins the handle it was told to', () async {
    const srcW = 400;
    const srcH = 400;
    final path = await source(srcW, srcH);
    ui.Rect predicted(double x, double y, double scale) => layerRectInSequence(
      seqW: seqW,
      seqH: seqH,
      srcW: srcW,
      srcH: srcH,
      framing: 'fit',
      x: x,
      y: y,
      scalePercent: scale,
    );

    final start = predicted(0, 0, 60);
    final drag = GizmoDrag(
      part: GizmoPart.resize,
      handle: 8, // bottom-right
      grab: start.bottomRight,
      rect: start,
      unitRect: predicted(0, 0, 100),
      restingX: 0,
      restingY: 0,
      restingScale: 60,
      drawnScale: 60,
      rotation: 0,
      symmetric: false,
    );
    final next = drag.resolve(start.bottomRight.translate(40, 40));

    final drawn = drawnRect(
      path: path,
      srcW: srcW,
      srcH: srcH,
      framing: 'fit',
      x: next.x!,
      y: next.y!,
      scale: next.scale!,
    );
    // The top-left corner is the one the drag pinned, so the engine must still
    // be putting pixels there after the resize.
    expect(drawn!.left, closeTo(start.left, 1));
    expect(drawn.top, closeTo(start.top, 1));
    expect(drawn.width, greaterThan(start.width));
  });
}
