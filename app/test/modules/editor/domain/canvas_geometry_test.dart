import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:crazycut_app/modules/editor/domain/canvas_geometry.dart';

/// The gizmo draws the rect the C++ compositor rasterises. These assertions
/// pin the maths in `engine/render/composite.cpp rasterizeLayer()`.
void main() {
  const seqW = 1920;
  const seqH = 1080;

  Rect rect({
    int srcW = 1000,
    int srcH = 1000,
    String framing = 'fit',
    double x = 0,
    double y = 0,
    double scale = 100,
    double anchorX = 0,
    double anchorY = 0,
  }) => layerRectInSequence(
    seqW: seqW,
    seqH: seqH,
    srcW: srcW,
    srcH: srcH,
    framing: framing,
    x: x,
    y: y,
    scalePercent: scale,
    anchorX: anchorX,
    anchorY: anchorY,
  );

  group('framing', () {
    test('fit letterboxes a square source inside a 16:9 canvas', () {
      final r = rect();
      expect(r.width, 1080);
      expect(r.height, 1080);
      expect(r.center, const Offset(960, 540));
    });

    test('fill covers the canvas and overflows the narrow axis', () {
      final r = rect(framing: 'fill');
      expect(r.width, 1920);
      expect(r.height, 1920);
      expect(r.top, lessThan(0));
    });

    test('stretch takes the canvas size regardless of source aspect', () {
      expect(rect(framing: 'stretch', srcW: 300, srcH: 4000).size,
          const Size(1920, 1080));
    });

    test('native keeps a text raster at its measured size', () {
      expect(
        rect(framing: 'native', srcW: 300, srcH: 100),
        const Rect.fromLTWH(810, 490, 300, 100),
      );
    });
  });

  test('x/y offset the rect from the canvas centre', () {
    expect(rect(x: 100, y: -50).center, const Offset(1060, 490));
  });

  test('scale grows the rect about its centre', () {
    final r = rect(scale: 200);
    expect(r.width, 2160);
    expect(r.center, const Offset(960, 540));
  });

  test('anchor shifts the rect by the anchor in final-image pixels', () {
    // 1000px source framed to 1080 => base scale 1.08.
    final r = rect(anchorX: 100);
    expect(r.center.dx, closeTo(960 + 108, 1e-9));
  });

  group('inverse', () {
    test('scaleForWidth round-trips through layerRectInSequence', () {
      final scale = scaleForWidth(
        seqW: seqW,
        seqH: seqH,
        srcW: 1000,
        srcH: 1000,
        framing: 'fit',
        targetWidth: 540,
      );
      expect(scale, closeTo(50, 1e-9));
      expect(rect(scale: scale!).width, closeTo(540, 1e-9));
    });

    test('scaleForHeight round-trips for a non-square source', () {
      final scale = scaleForHeight(
        seqW: seqW,
        seqH: seqH,
        srcW: 4000,
        srcH: 3000,
        framing: 'fit',
        targetHeight: 270,
      );
      expect(rect(srcW: 4000, srcH: 3000, scale: scale!).height,
          closeTo(270, 1e-9));
    });

    test('a zero-sized source yields no scale rather than an infinity', () {
      expect(
        scaleForWidth(
          seqW: seqW,
          seqH: seqH,
          srcW: 0,
          srcH: 0,
          framing: 'fit',
          targetWidth: 100,
        ),
        isNull,
      );
    });
  });

  group('rotatePoint', () {
    test('turns clockwise on screen, matching the engine sign convention', () {
      final p = rotatePoint(const Offset(10, 0), Offset.zero, 90);
      expect(p.dx, closeTo(0, 1e-9));
      expect(p.dy, closeTo(10, 1e-9));
    });

    test('is its own inverse at the negated angle', () {
      const start = Offset(37, -12);
      const about = Offset(5, 5);
      final round = rotatePoint(rotatePoint(start, about, 37), about, -37);
      expect(round.dx, closeTo(start.dx, 1e-9));
      expect(round.dy, closeTo(start.dy, 1e-9));
    });
  });

  test('gizmoAnchors puts opposite handles at index 8 - i', () {
    final anchors = gizmoAnchors(const Rect.fromLTWH(0, 0, 100, 50));
    for (var i = 0; i < 9; i += 1) {
      final opposite = anchors[8 - i];
      expect(anchors[i].dx + opposite.dx, closeTo(100, 1e-9));
      expect(anchors[i].dy + opposite.dy, closeTo(50, 1e-9));
    }
  });

  group('GizmoDrag', () {
    // A 1000x1000 source fitted to 1920x1080 draws as a centred 1080 square.
    final unit = rect();

    GizmoDrag drag({
      required GizmoPart part,
      int handle = 4,
      required Offset grab,
      Rect? drawn,
      double restingX = 0,
      double restingY = 0,
      double restingScale = 100,
      double? drawnScale,
      double rotation = 0,
      bool symmetric = false,
      Size canvasSize = Size.zero,
      List<(Rect, double)> companions = const [],
    }) => GizmoDrag(
      part: part,
      handle: handle,
      grab: grab,
      rect: drawn ?? unit,
      unitRect: unit,
      restingX: restingX,
      restingY: restingY,
      restingScale: restingScale,
      drawnScale: drawnScale ?? restingScale,
      rotation: rotation,
      symmetric: symmetric,
      canvasSize: canvasSize,
      companions: companions,
    );

    test('move tracks the pointer one-for-one', () {
      final d = drag(part: GizmoPart.move, grab: const Offset(960, 540));
      final next = d.resolve(const Offset(1060, 440));
      expect(next.x, 100);
      expect(next.y, -100);
      expect(next.scale, isNull);
    });

    test('move snaps onto the canvas centre within the catch distance', () {
      final d = drag(
        part: GizmoPart.move,
        grab: const Offset(960, 540),
        canvasSize: const Size(1920, 1080),
      );
      // A 5px nudge off dead-centre still resolves onto it...
      final caught = d.resolve(const Offset(965, 540), moveSnapDistance: 10);
      expect(caught.x, 0);
      expect(d.snapVerticals, [960.0]);

      // ...but a nudge past the catch distance is left alone.
      final missed = d.resolve(const Offset(985, 540), moveSnapDistance: 10);
      expect(missed.x, 25);
      expect(d.snapVerticals, isEmpty);
    });

    test("move snaps onto another selected clip's centre", () {
      final d = drag(
        part: GizmoPart.move,
        grab: const Offset(105, 540),
        restingX: -855,
        canvasSize: const Size(1920, 1080),
        companions: const [(Rect.fromLTWH(0, 0, 200, 200), 0)],
      );
      final next = d.resolve(const Offset(105, 540), moveSnapDistance: 10);
      // Companion centre sits at x=100; the rect's own centre started 5px shy.
      expect(next.x, closeTo(-860, 1e-9));
      expect(d.snapVerticals, [100.0]);
    });

    test('move adds to the resting pose, not to the drawn position', () {
      // Mid slide-in the rect is drawn 200px right of where it rests.
      final d = drag(
        part: GizmoPart.move,
        grab: const Offset(960, 540),
        drawn: unit.translate(200, 0),
        restingX: 0,
      );
      expect(d.resolve(const Offset(1010, 540)).x, 50);
    });

    test('dragging a corner outwards scales up and pins the far corner', () {
      final d = drag(
        part: GizmoPart.resize,
        handle: 8, // bottom-right
        grab: unit.bottomRight,
      );
      // Push the corner out by half the rect: 1080 -> 1620, i.e. 150%.
      final next = d.resolve(unit.bottomRight.translate(540, 540));
      expect(next.scale, closeTo(150, 1e-9));

      final resized = rect(x: next.x!, y: next.y!, scale: next.scale!);
      expect(resized.topLeft.dx, closeTo(unit.topLeft.dx, 1e-6));
      expect(resized.topLeft.dy, closeTo(unit.topLeft.dy, 1e-6));
    });

    test('dragging inwards shrinks and never crosses zero', () {
      final d = drag(
        part: GizmoPart.resize,
        handle: 0, // top-left
        grab: unit.topLeft,
      );
      // Drag well past the pinned corner; the ratio is taken as a magnitude.
      final next = d.resolve(unit.bottomRight.translate(200, 200));
      expect(next.scale, greaterThan(0));
    });

    test('an edge handle still scales uniformly and keeps the far edge', () {
      final d = drag(
        part: GizmoPart.resize,
        handle: 5, // centre-right
        grab: unit.centerRight,
      );
      // The far edge is pinned, so pushing 540 out of a 1080-wide rect is 150%.
      final next = d.resolve(unit.centerRight.translate(540, 0));
      expect(next.scale, closeTo(150, 1e-9));

      final resized = rect(x: next.x!, y: next.y!, scale: next.scale!);
      expect(resized.left, closeTo(unit.left, 1e-6));
      // Uniform means the height grew too, symmetrically about the pinned edge.
      expect(resized.center.dy, closeTo(unit.center.dy, 1e-6));
    });

    test('a symmetric resize grows about the centre and leaves x/y alone', () {
      final d = drag(
        part: GizmoPart.resize,
        handle: 8,
        grab: unit.bottomRight,
        symmetric: true,
      );
      // Pinned at the centre, both sides grow: the same travel is worth twice
      // what it is worth against a pinned corner.
      final next = d.resolve(unit.bottomRight.translate(540, 540));
      expect(next.scale, closeTo(200, 1e-9));
      expect(next.x, isNull);
      expect(next.y, isNull);
    });

    test('a rotated rect resizes along its own edges', () {
      // Rotated 90 degrees, the right-hand handle is drawn at the bottom.
      final d = drag(
        part: GizmoPart.resize,
        handle: 5,
        grab: rotatePoint(unit.centerRight, unit.center, 90),
        rotation: 90,
      );
      final next = d.resolve(
        rotatePoint(unit.centerRight.translate(540, 0), unit.center, 90),
      );
      expect(next.scale, closeTo(150, 1e-9));
    });

    test('scale is multiplicative on the resting value', () {
      // The clip rests at 50%; doubling the drawn size must land on 100%.
      final drawn = rect(scale: 50);
      final d = drag(
        part: GizmoPart.resize,
        handle: 8,
        grab: drawn.bottomRight,
        drawn: drawn,
        restingScale: 50,
      );
      final next = d.resolve(
        drawn.topLeft + (drawn.bottomRight - drawn.topLeft) * 2,
      );
      expect(next.scale, closeTo(100, 1e-9));
    });

    test('scale clamps to the inspector range', () {
      final d = drag(
        part: GizmoPart.resize,
        handle: 8,
        grab: unit.bottomRight,
      );
      expect(d.resolve(const Offset(100000, 100000)).scale, 400);
    });

    test('rotate reports the angle swept around the centre', () {
      final d = drag(
        part: GizmoPart.rotate,
        grab: unit.center.translate(0, -400),
      );
      final next = d.resolve(unit.center.translate(400, 0));
      expect(next.rotation, closeTo(90, 1e-9));
      expect(next.x, isNull);
      expect(next.scale, isNull);
    });

    test('rotate snaps to 15 degree steps', () {
      final d = drag(
        part: GizmoPart.rotate,
        grab: unit.center.translate(0, -400),
      );
      // 20 degrees past straight up snaps back to 15.
      final pointer = rotatePoint(unit.center.translate(0, -400), unit.center, 20);
      expect(d.resolve(pointer).rotation, closeTo(20, 1e-6));
      expect(d.resolve(pointer, snap: true).rotation, closeTo(15, 1e-9));
    });

    test('rotate wraps past a half turn into the negative half', () {
      final d = drag(
        part: GizmoPart.rotate,
        grab: unit.center.translate(0, -400),
      );
      final pointer = rotatePoint(unit.center.translate(0, -400), unit.center, 200);
      expect(d.resolve(pointer).rotation, closeTo(-160, 1e-6));
    });
  });

  // --- Align & distribute (FX-15) -----------------------------------------

  group('rotatedBounds', () {
    test('leaves an unrotated rect alone', () {
      const rect = Rect.fromLTWH(10, 20, 100, 50);
      expect(rotatedBounds(rect, 0), rect);
      expect(rotatedBounds(rect, 360), rect);
    });

    test('90° swaps the extents about the same centre', () {
      const rect = Rect.fromLTWH(0, 0, 100, 50);
      final out = rotatedBounds(rect, 90);
      expect(out.width, closeTo(50, 1e-9));
      expect(out.height, closeTo(100, 1e-9));
      expect(out.center.dx, closeTo(rect.center.dx, 1e-9));
      expect(out.center.dy, closeTo(rect.center.dy, 1e-9));
    });

    test('45° grows a square by √2', () {
      const rect = Rect.fromLTWH(0, 0, 100, 100);
      final out = rotatedBounds(rect, 45);
      expect(out.width, closeTo(100 * 1.41421356, 1e-4));
      expect(out.height, closeTo(100 * 1.41421356, 1e-4));
    });
  });

  group('alignDeltas', () {
    // Two boxes that share no edge, so every edge produces a distinct answer.
    final boxes = [
      const Rect.fromLTWH(0, 0, 100, 40),
      const Rect.fromLTWH(200, 100, 60, 80),
    ];

    test('lines items up on the union of the selection', () {
      // Union is (0,0)-(260,180).
      expect(alignDeltas(boxes, AlignEdge.left), [
        Offset.zero,
        const Offset(-200, 0),
      ]);
      expect(alignDeltas(boxes, AlignEdge.right), [
        const Offset(160, 0),
        Offset.zero,
      ]);
      expect(alignDeltas(boxes, AlignEdge.top), [
        Offset.zero,
        const Offset(0, -100),
      ]);
      expect(alignDeltas(boxes, AlignEdge.bottom), [
        const Offset(0, 140),
        Offset.zero,
      ]);
      expect(alignDeltas(boxes, AlignEdge.centerX), [
        const Offset(80, 0),
        const Offset(-100, 0),
      ]);
      expect(alignDeltas(boxes, AlignEdge.centerY), [
        const Offset(0, 70),
        const Offset(0, -50),
      ]);
    });

    test('lines items up on an explicit frame', () {
      const frame = Rect.fromLTWH(0, 0, 1000, 500);
      expect(
        alignDeltas(boxes, AlignEdge.right, frame: frame),
        [const Offset(900, 0), const Offset(740, 0)],
      );
      expect(
        alignDeltas(boxes, AlignEdge.centerY, frame: frame),
        [const Offset(0, 230), const Offset(0, 110)],
      );
    });

    test('an empty selection has nothing to align', () {
      expect(alignDeltas(const [], AlignEdge.left), isEmpty);
    });
  });

  group('distributeDeltas', () {
    test('equalises the gaps and pins the outermost items', () {
      final boxes = [
        const Rect.fromLTWH(0, 0, 100, 10),
        const Rect.fromLTWH(120, 0, 100, 10),
        const Rect.fromLTWH(700, 0, 100, 10),
      ];
      final deltas = distributeDeltas(boxes, AlignAxis.horizontal);
      // Span 0..800, 300px of content, so two gaps of 250.
      expect(deltas[0], Offset.zero, reason: 'the first item is the anchor');
      expect(deltas[2], Offset.zero, reason: 'the last item is the anchor');
      expect(deltas[1].dx, closeTo(230, 1e-9)); // 350 - 120
      expect(deltas.every((d) => d.dy == 0), isTrue);
    });

    test('works off centres, not input order', () {
      final boxes = [
        const Rect.fromLTWH(0, 700, 10, 100),
        const Rect.fromLTWH(0, 0, 10, 100),
        const Rect.fromLTWH(0, 120, 10, 100),
      ];
      final deltas = distributeDeltas(boxes, AlignAxis.vertical);
      expect(deltas[0], Offset.zero);
      expect(deltas[1], Offset.zero);
      expect(deltas[2].dy, closeTo(230, 1e-9));
    });

    test('fewer than three items has nothing to spread', () {
      final boxes = [
        const Rect.fromLTWH(0, 0, 10, 10),
        const Rect.fromLTWH(500, 0, 10, 10),
      ];
      expect(
        distributeDeltas(boxes, AlignAxis.horizontal),
        [Offset.zero, Offset.zero],
      );
    });
  });
}
