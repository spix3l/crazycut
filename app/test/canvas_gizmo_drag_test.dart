import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' hide Clip;
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/data/clip_transform.dart';
import 'package:crazycut_app/data/param_value.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/engine/engine.dart';
import 'package:crazycut_app/features/editor/presentation/widgets/canvas_gizmo.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/canvas_geometry.dart';
import 'package:crazycut_app/state/editor_controller.dart';

/// The gizmo's handles and the composited image are drawn by two different
/// programs — a Flutter painter and the C++ compositor — from the same
/// transform. `canvas_gizmo_parity_test.dart` pins that geometry down; this
/// test drives the widget the way a user does, so a regression anywhere in
/// between (hit test, drag resolution, rebasing an animated clip) surfaces as
/// the image no longer sitting inside its own handles.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const seqW = 1920, seqH = 1080;
  const srcW = 540, srcH = 540;
  // Opaque region inside the source, so the drawn bounding box is a known
  // fraction of the layer rect rather than the whole of it — an image with
  // transparent margins is the normal case for the logos this feature exists
  // for, and it is where an off-by-a-rect bug hides.
  const padL = 67, padT = 84, padR = 471, padB = 456;

  late Directory tmp;
  late String pngPath;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('cc-gizmo-drag');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTRB(
        padL.toDouble(),
        padT.toDouble(),
        padR.toDouble(),
        padB.toDouble(),
      ),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final image = await recorder.endRecording().toImage(srcW, srcH);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    pngPath = '${tmp.path}/logo.png';
    File(pngPath).writeAsBytesSync(png!.buffer.asUint8List());
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  ProjectDoc buildDoc() {
    final doc = ProjectDoc.empty('P', width: seqW, height: seqH, fps: 30);
    doc.media.add(
      MediaAsset(
        id: 'i',
        name: 'logo.png',
        path: pngPath,
        type: 'image',
        duration: Rt.fromSeconds(5),
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
        label: 'logo',
        start: Rt.zero(),
        duration: Rt.fromSeconds(5),
        sourceIn: Rt.zero(),
        transform: ClipTransform(
          x: ParamValue.staticNum(-100),
          y: ParamValue.staticNum(-30),
          scale: ParamValue.staticNum(40),
        ),
      ),
    );
    return doc;
  }

  /// Bounding box of what the engine actually drew, in document pixels.
  ui.Rect drawnRect(ProjectDoc doc, Rt time, {int renderWidth = 1280}) {
    final renderHeight = (renderWidth * seqH / seqW).round();
    final engine = CrazyCutEngine.instance;
    engine.setProjectSnapshot(doc.encode(touchModified: false));
    final frame = engine.renderFrameRgba(
      time: time,
      width: renderWidth,
      height: renderHeight,
      mediaPaths: {'i': pngPath},
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
    expect(right, greaterThan(0), reason: 'nothing was drawn');
    final kx = seqW / renderWidth, ky = seqH / renderHeight;
    return ui.Rect.fromLTRB(
      left * kx,
      top * ky,
      (right + 1) * kx,
      (bottom + 1) * ky,
    );
  }

  /// Where the opaque part of the source lands, given the layer rect the gizmo
  /// drew its handles around.
  ui.Rect opaquePartOf(ui.Rect layer) => ui.Rect.fromLTRB(
    layer.left + layer.width * padL / srcW,
    layer.top + layer.height * padT / srcH,
    layer.left + layer.width * padR / srcW,
    layer.top + layer.height * padB / srcH,
  );

  Future<void> expectImageInsideHandles(
    WidgetTester tester, {
    required EditorController c,
    required ui.Offset dragBy,
    required bool animated,
  }) async {
    final doc = c.doc;
    final clip = doc.clips.single;
    const boxW = 1114.0, boxH = 626.0;
    tester.view.physicalSize = const ui.Size(boxW, boxH);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: boxW,
            height: boxH,
            child: CanvasGizmo(controller: c),
          ),
        ),
      ),
    );
    await tester.pump();

    double evaluate(ParamValue param, double fallback) {
      final v = param.evaluate(c.playhead.minus(clip.start));
      return v is num ? v.toDouble() : fallback;
    }

    ui.Rect gizmoRect() {
      final t = clip.transformOrDefault;
      return layerRectInSequence(
        seqW: seqW,
        seqH: seqH,
        srcW: srcW,
        srcH: srcH,
        framing: t.framing,
        x: evaluate(t.x, 0),
        y: evaluate(t.y, 0),
        scalePercent: evaluate(t.scale, 100),
      );
    }

    final before = gizmoRect();
    final origin = tester.getTopLeft(find.byType(CanvasGizmo));
    final seqPerPx = seqW / boxW;
    final gesture = await tester.startGesture(
      origin + ui.Offset(before.center.dx / seqPerPx, before.center.dy / seqPerPx),
    );
    // In steps, like a real pointer.
    for (var i = 0; i < 4; i += 1) {
      await gesture.moveBy(dragBy / 4);
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    final after = gizmoRect();
    expect(
      after.center.dx - before.center.dx,
      closeTo(dragBy.dx * seqPerPx, 1.0),
      reason: 'the handles should follow the pointer 1:1',
    );
    expect(
      after.center.dy - before.center.dy,
      closeTo(dragBy.dy * seqPerPx, 1.0),
    );
    if (animated) {
      expect(
        c.imageAnimSpec(clip),
        isNotNull,
        reason: 'the drag must not delete the clip animation',
      );
    }

    final drawn = drawnRect(doc, c.playhead);
    final expected = opaquePartOf(after);
    // One render pixel of the 1280-wide preview is 1.5 document px.
    expect(drawn.left, closeTo(expected.left, 2));
    expect(drawn.top, closeTo(expected.top, 2));
    expect(drawn.right, closeTo(expected.right, 2));
    expect(drawn.bottom, closeTo(expected.bottom, 2));
  }

  testWidgets('dragging a plain image lands it inside its own handles', (
    tester,
  ) async {
    final doc = buildDoc();
    final c = EditorController(doc, path: '${tmp.path}/p.crazycut');
    c.playhead = Rt.fromSeconds(2);
    c.selection.add('c');
    await expectImageInsideHandles(
      tester,
      c: c,
      dragBy: const ui.Offset(120, 60),
      animated: false,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('dragging an animated image moves its resting pose', (
    tester,
  ) async {
    final doc = buildDoc();
    final c = EditorController(doc, path: '${tmp.path}/p2.crazycut');
    // Entry and exit animations regenerate keyframes from a stored resting
    // pose, so a drag has to move that pose rather than write a raw key the
    // next rebuild would erase.
    c.setImageEntryExit('c', appear: 'pop', disappear: 'fade');
    // Mid-clip: past the entry, before the exit, where the pose is the pose.
    c.playhead = Rt.fromSeconds(2);
    c.selection.add('c');
    await expectImageInsideHandles(
      tester,
      c: c,
      dragBy: const ui.Offset(-90, 70),
      animated: true,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('clicking an image drags that image, not the selected one', (
    tester,
  ) async {
    final doc = buildDoc();
    final c = EditorController(doc, path: '${tmp.path}/p3.crazycut');
    // A second image on a track above, off to the right so the two rects do
    // not cover each other.
    final upper = c.addTrack('video');
    doc.clips.add(
      Clip(
        id: 'c2',
        trackId: upper.id,
        mediaId: 'i',
        label: 'logo 2',
        start: Rt.zero(),
        duration: Rt.fromSeconds(5),
        sourceIn: Rt.zero(),
        transform: ClipTransform(
          x: ParamValue.staticNum(400),
          y: ParamValue.staticNum(0),
          scale: ParamValue.staticNum(40),
        ),
      ),
    );
    c.playhead = Rt.fromSeconds(2);
    // The *other* clip is selected, which is exactly the case that used to
    // move the wrong image.
    c.selection.add('c');

    const boxW = 1114.0, boxH = 626.0;
    tester.view.physicalSize = const ui.Size(boxW, boxH);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: boxW,
            height: boxH,
            child: CanvasGizmo(controller: c),
          ),
        ),
      ),
    );
    await tester.pump();

    final other = doc.clipById('c')!;
    final otherX = other.transformOrDefault.x.static;
    final second = doc.clipById('c2')!;
    final rect = layerRectInSequence(
      seqW: seqW,
      seqH: seqH,
      srcW: srcW,
      srcH: srcH,
      framing: 'fit',
      x: 400,
      y: 0,
      scalePercent: 40,
    );
    final seqPerPx = seqW / boxW;
    final origin = tester.getTopLeft(find.byType(CanvasGizmo));
    await tester.dragFrom(
      origin + ui.Offset(rect.center.dx / seqPerPx, rect.center.dy / seqPerPx),
      const ui.Offset(60, 30),
    );
    await tester.pump();

    expect(c.selection, {'c2'}, reason: 'the click selects what it landed on');
    expect(
      (second.transformOrDefault.x.static as num) - 400,
      closeTo(60 * seqPerPx, 1),
    );
    expect(
      other.transformOrDefault.x.static,
      otherX,
      reason: 'the image that was not clicked must not move',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
