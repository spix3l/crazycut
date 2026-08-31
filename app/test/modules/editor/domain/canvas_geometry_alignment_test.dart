import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' hide Clip;
import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/editor/presentation/widgets/inspector/inspector_transform_tab.dart';

import 'package:crazycut_app/modules/project/domain/clip_transform.dart';
import 'package:crazycut_app/modules/project/domain/param_value.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/domain/canvas_geometry.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import '../../../support/temp_dir.dart';

/// Align & distribute (FX-15) as the controller runs it: the right clips move,
/// by the right amount, in one undo step. The pure maths underneath lives in
/// `canvas_geometry_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const seqW = 1920, seqH = 1080;
  const srcW = 540, srcH = 540;
  // 'fit' base scale is 1080/540 = 2, so `scale: 40` draws a 432×432 box.
  const drawn = 432.0;

  late Directory tmp;
  late String pngPath;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('cc-align');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 540, 540),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final image = await recorder.endRecording().toImage(srcW, srcH);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    pngPath = '${tmp.path}/logo.png';
    File(pngPath).writeAsBytesSync(png!.buffer.asUint8List());
  });

  tearDownAll(() => deleteTempDir(tmp));

  /// A controller with [xs].length image clips, each on its own video track so
  /// they can all sit under the playhead at once, at `scale: 40`.
  ///
  /// Deliberately never disposed: the constructor kicks off thumbnail decoding
  /// that notifies listeners when it lands, and disposing mid-flight throws.
  /// These tests only exercise synchronous ops, so letting it be collected is
  /// simpler than pumping an event loop that is not otherwise needed.
  EditorController harness(String name, List<double> xs, {List<double>? ys}) {
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
    final c = EditorController(doc, path: '${tmp.path}/$name.crazycut');
    for (var i = 0; i < xs.length; i += 1) {
      final trackId = i == 0 ? doc.videoTrack()!.id : c.addTrack('video').id;
      doc.clips.add(
        Clip(
          id: 'c$i',
          trackId: trackId,
          mediaId: 'i',
          label: 'logo $i',
          start: Rt.zero(),
          duration: Rt.fromSeconds(5),
          sourceIn: Rt.zero(),
          transform: ClipTransform(
            x: ParamValue.staticNum(xs[i]),
            y: ParamValue.staticNum(ys?[i] ?? 0),
            scale: ParamValue.staticNum(40),
          ),
        ),
      );
      c.selection.add('c$i');
    }
    c.playhead = Rt.fromSeconds(2);
    return c;
  }

  double xOf(EditorController c, String id) =>
      (c.doc.clipById(id)!.transformOrDefault.x.static as num).toDouble();
  double yOf(EditorController c, String id) =>
      (c.doc.clipById(id)!.transformOrDefault.y.static as num).toDouble();

  test('align left pulls the selection onto its own leftmost edge', () {
    final c = harness('left', [-300, 200]);
    c.alignClips(AlignEdge.left);

    expect(xOf(c, 'c0'), closeTo(-300, 0.001), reason: 'already leftmost');
    expect(xOf(c, 'c1'), closeTo(-300, 0.001));
    expect(
      c.clipBoundsInSequence(c.doc.clipById('c0')!)!.left,
      closeTo(c.clipBoundsInSequence(c.doc.clipById('c1')!)!.left, 0.001),
    );
  });

  test('align bottom moves on Y only', () {
    final c = harness('bottom', [-300, 200], ys: [-100, 240]);
    c.alignClips(AlignEdge.bottom);

    expect(xOf(c, 'c0'), closeTo(-300, 0.001));
    expect(xOf(c, 'c1'), closeTo(200, 0.001));
    expect(yOf(c, 'c0'), closeTo(240, 0.001));
    expect(yOf(c, 'c1'), closeTo(240, 0.001));
  });

  test(
    'a fully linked group aligns to the canvas, not its own bounding box',
    () {
      // Two clips sharing a linked group, sitting off-centre together — the
      // link makes this one composite object, not two independent images, so
      // aligning it should move it against the canvas like a single clip
      // would rather than being a no-op against its own already-shared bbox.
      final c = harness('linked-group', [-300, 200], ys: [100, 100]);
      c.doc.clipById('c0')!.linkedGroup = 'g';
      c.doc.clipById('c1')!.linkedGroup = 'g';

      c.alignClips(AlignEdge.centerY);

      expect(yOf(c, 'c0'), closeTo(0, 0.001));
      expect(yOf(c, 'c1'), closeTo(0, 0.001));
    },
  );

  test(
    'clips linked into different groups still align against each other',
    () {
      final c = harness('mixed-groups', [-300, 200], ys: [-100, 240]);
      c.doc.clipById('c0')!.linkedGroup = 'g1';
      c.doc.clipById('c1')!.linkedGroup = 'g2';

      c.alignClips(AlignEdge.bottom);

      expect(yOf(c, 'c0'), closeTo(240, 0.001));
      expect(yOf(c, 'c1'), closeTo(240, 0.001));
    },
  );

  test('a single selected clip aligns to the sequence canvas', () {
    final c = harness('single', [120]);
    c.alignClips(AlignEdge.left);

    // Canvas centre is 960; a 432-wide box hugging the left edge sits at
    // x = -(960 - 216).
    expect(xOf(c, 'c0'), closeTo(-(seqW / 2 - drawn / 2), 0.001));
    expect(
      c.clipBoundsInSequence(c.doc.clipById('c0')!)!.left,
      closeTo(0, 0.001),
    );

    c.alignClips(AlignEdge.centerX);
    expect(xOf(c, 'c0'), closeTo(0, 0.001));
  });

  test('a rotated clip aligns by the box it actually occupies', () {
    final c = harness('rotated', [0]);
    c.setTransformParam('c0', 'rotation', 45);
    c.alignClips(AlignEdge.left);

    final bounds = c.clipBoundsInSequence(c.doc.clipById('c0')!)!;
    expect(bounds.left, closeTo(0, 0.001));
    expect(bounds.width, closeTo(drawn * 1.41421356, 0.01));
  });

  test('distribute equalises the gaps and leaves the extremes put', () {
    final c = harness('distribute', [-700, -600, 700]);
    c.distributeClips(AlignAxis.horizontal);

    expect(xOf(c, 'c0'), closeTo(-700, 0.001));
    expect(xOf(c, 'c2'), closeTo(700, 0.001));
    expect(xOf(c, 'c1'), closeTo(0, 0.001), reason: 'the midpoint of the span');
  });

  test('distribute needs three clips', () {
    final c = harness('distribute2', [-700, 700]);
    c.distributeClips(AlignAxis.horizontal);

    expect(xOf(c, 'c0'), closeTo(-700, 0.001));
    expect(xOf(c, 'c1'), closeTo(700, 0.001));
    expect(c.canUndo, isFalse, reason: 'a no-op must not push a command');
  });

  test('the whole batch is one undo step', () {
    final c = harness('undo', [-300, 200, 640]);
    final before = [for (var i = 0; i < 3; i += 1) xOf(c, 'c$i')];

    c.alignClips(AlignEdge.right);
    expect([for (var i = 0; i < 3; i += 1) xOf(c, 'c$i')], isNot(before));

    c.undo();
    expect([for (var i = 0; i < 3; i += 1) xOf(c, 'c$i')], before);
    expect(c.canUndo, isFalse);
  });

  test('unselected and unaligned clips stay put', () {
    final c = harness('subset', [-300, 200, 640]);
    c.selection.remove('c2');
    final untouched = xOf(c, 'c2');

    c.alignClips(AlignEdge.left);
    expect(xOf(c, 'c2'), untouched);
    expect(c.alignableClips().map((e) => e.id).toSet(), {'c0', 'c1'});
  });

  testWidgets('the Transform tab offers align to whatever is selected', (
    tester,
  ) async {
    final c = harness('tab', [-300, 200]);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 280,
            height: 900,
            child: TransformTab(controller: c, clip: c.doc.clipById('c0')!),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('to selection'), findsOneWidget);
    // 6 align + 2 distribute, before the rows below add any of their own.
    final buttons = find.byType(CcIconButton);
    expect(buttons, findsNWidgets(8));

    await tester.tap(buttons.first); // align left
    await tester.pump();
    expect(xOf(c, 'c1'), closeTo(-300, 0.001));

    // One clip selected switches the reference to the frame itself.
    c.selection.remove('c1');
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 280,
            height: 900,
            child: TransformTab(controller: c, clip: c.doc.clipById('c0')!),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('to canvas'), findsOneWidget);
    c.dispose();
  });
}
