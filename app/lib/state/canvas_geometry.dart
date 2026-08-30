/// Geometry shared by the on-canvas transform gizmo and the C++ compositor.
///
/// Every function here mirrors `engine/render/composite.cpp rasterizeLayer()`.
/// The gizmo has to draw the *same* rectangle the engine rasterises, so if that
/// function's framing/anchor maths ever changes, change these with it.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// Base scale that maps a `srcW`×`srcH` source onto a `seqW`×`seqH` canvas for
/// a framing mode. `stretch` is 1.0 because it scales each axis separately.
double framingBaseScale({
  required int seqW,
  required int seqH,
  required int srcW,
  required int srcH,
  required String framing,
}) {
  if (srcW <= 0 || srcH <= 0) return 1.0;
  final sx = seqW / srcW;
  final sy = seqH / srcH;
  return switch (framing) {
    'native' => 1.0,
    'stretch' => 1.0,
    'fill' => math.max(sx, sy),
    _ => math.min(sx, sy),
  };
}

/// Rect the clip's image occupies on the sequence canvas, in sequence pixels,
/// before rotation. `x`/`y` are offsets from the canvas centre, `scalePercent`
/// is the transform's `scale` (100 = framed size), `anchor` is in source px.
Rect layerRectInSequence({
  required int seqW,
  required int seqH,
  required int srcW,
  required int srcH,
  required String framing,
  required double x,
  required double y,
  required double scalePercent,
  double anchorX = 0,
  double anchorY = 0,
}) {
  final scale = scalePercent / 100.0;
  final total =
      framingBaseScale(
        seqW: seqW,
        seqH: seqH,
        srcW: srcW,
        srcH: srcH,
        framing: framing,
      ) *
      scale;
  final double dw;
  final double dh;
  if (framing == 'native') {
    dw = srcW * scale;
    dh = srcH * scale;
  } else if (framing == 'stretch') {
    dw = seqW * scale;
    dh = seqH * scale;
  } else {
    dw = srcW * total;
    dh = srcH * total;
  }
  // rasterizeLayer() offsets the sampling origin by the anchor expressed in
  // final-image pixels, which shifts the drawn rect by the same amount.
  final cx = seqW / 2.0 + x + anchorX * total;
  final cy = seqH / 2.0 + y + anchorY * total;
  return Rect.fromLTWH(cx - dw / 2, cy - dh / 2, dw, dh);
}

/// Inverse of [layerRectInSequence] for width: the `scale` % whose rect is
/// [targetWidth] wide. Returns null when the source has no usable width.
double? scaleForWidth({
  required int seqW,
  required int seqH,
  required int srcW,
  required int srcH,
  required String framing,
  required double targetWidth,
}) {
  final unit = layerRectInSequence(
    seqW: seqW,
    seqH: seqH,
    srcW: srcW,
    srcH: srcH,
    framing: framing,
    x: 0,
    y: 0,
    scalePercent: 100,
  ).width;
  if (unit <= 0) return null;
  return targetWidth / unit * 100.0;
}

/// Inverse of [layerRectInSequence] for height.
double? scaleForHeight({
  required int seqW,
  required int seqH,
  required int srcW,
  required int srcH,
  required String framing,
  required double targetHeight,
}) {
  final unit = layerRectInSequence(
    seqW: seqW,
    seqH: seqH,
    srcW: srcW,
    srcH: srcH,
    framing: framing,
    x: 0,
    y: 0,
    scalePercent: 100,
  ).height;
  if (unit <= 0) return null;
  return targetHeight / unit * 100.0;
}

/// Rotates [point] around [about] by [degrees] clockwise on screen.
///
/// The engine composites with `rad = -rotationDeg * pi/180` because screen Y
/// grows downward; a positive `rotation` therefore turns clockwise on screen,
/// which is what this produces.
Offset rotatePoint(Offset point, Offset about, double degrees) {
  if (degrees == 0) return point;
  final rad = degrees * math.pi / 180.0;
  final cos = math.cos(rad);
  final sin = math.sin(rad);
  final dx = point.dx - about.dx;
  final dy = point.dy - about.dy;
  return Offset(
    about.dx + dx * cos - dy * sin,
    about.dy + dx * sin + dy * cos,
  );
}

/// The nine gizmo anchor points of [rect]: 8 handles plus the centre. Indices
/// are `(row, col)` flattened, so the opposite of index `i` is `8 - i`.
List<Offset> gizmoAnchors(Rect rect) => [
  rect.topLeft,
  rect.topCenter,
  rect.topRight,
  rect.centerLeft,
  rect.center,
  rect.centerRight,
  rect.bottomLeft,
  rect.bottomCenter,
  rect.bottomRight,
];

/// Which part of the gizmo a pointer grabbed. Handle indices index
/// [gizmoAnchors], so the handle opposite `i` is always `8 - i`.
enum GizmoPart { none, move, resize, rotate }

/// The transform values a drag resolves to. Nulls are "leave this alone".
typedef GizmoTransform = ({double? x, double? y, double? scale, double? rotation});

/// Unit vector from a rect's centre towards anchor [index], in the rect's own
/// unrotated frame.
Offset gizmoAnchorDirection(int index) => Offset(
  switch (index % 3) { 0 => -1.0, 2 => 1.0, _ => 0.0 },
  switch (index ~/ 3) { 0 => -1.0, 2 => 1.0, _ => 0.0 },
);

/// One in-flight gizmo drag, captured at pointer-down and asked for a new
/// transform on every pointer move. Pure maths in sequence pixels — no widgets,
/// no controller — so the awkward cases (rotated resize, a pinned corner, an
/// entry animation offsetting the image) are testable on their own.
///
/// Values are resolved against the clip's *resting* pose, because that is what
/// a direct-manipulation write moves on a clip whose animation is generated.
class GizmoDrag {
  GizmoDrag({
    required this.part,
    required this.handle,
    required this.grab,
    required Rect rect,
    required this.unitRect,
    required this.restingX,
    required this.restingY,
    required this.restingScale,
    required this.drawnScale,
    required this.rotation,
    required this.symmetric,
    this.canvasSize = Size.zero,
    this.companions = const [],
  }) : centre = rect.center,
       // The point a resize must pin: the opposite handle, or the centre when
       // the drag is symmetric.
       _fixedUnrotated =
           symmetric ? rect.center : gizmoAnchors(rect)[8 - handle],
       _fixedOnScreen = rotatePoint(
         symmetric ? rect.center : gizmoAnchors(rect)[8 - handle],
         rect.center,
         rotation,
       ),
       _startAngle = math.atan2(
         grab.dy - rect.center.dy,
         grab.dx - rect.center.dx,
       );

  static const double minScale = 1;
  static const double maxScale = 400;

  final GizmoPart part;
  final int handle;

  /// Pointer position at pointer-down, in sequence pixels.
  final Offset grab;

  /// Centre of the drawn rect at pointer-down.
  final Offset centre;

  /// The rect the clip would occupy at `scale` 100 — the yardstick a drag is
  /// converted back into a scale percentage with.
  final Rect unitRect;

  final double restingX;
  final double restingY;
  final double restingScale;

  /// Scale the rect is actually drawn at, which differs from [restingScale]
  /// while a generated entry/exit animation is playing.
  final double drawnScale;
  final double rotation;

  /// Alt-style resize: the centre stays put and both sides grow.
  final bool symmetric;

  /// The sequence canvas size, used to offer its edges and centre as snap
  /// targets for a move drag.
  final Size canvasSize;

  /// The other selected clips' unrotated rects and rotations at drag start,
  /// offered as snap targets for a move drag alongside the canvas itself.
  final List<(Rect, double)> companions;

  /// Snap lines a move drag last landed on, in sequence pixels — vertical
  /// lines carry an x, horizontal lines carry a y. Empty when nothing is
  /// within [moveSnapDistance] or the drag is not a move. Read by the painter
  /// to draw "magnet" alignment guides across the canvas.
  List<double> snapVerticals = const [];
  List<double> snapHorizontals = const [];

  final Offset _fixedUnrotated;
  final Offset _fixedOnScreen;
  final double _startAngle;

  /// The transform [pointer] resolves to. [snap] rounds rotation to 15°.
  /// [moveSnapDistance] is the "magnet" catch radius in sequence pixels for a
  /// move drag — 0 disables snapping.
  GizmoTransform resolve(
    Offset pointer, {
    bool snap = false,
    double moveSnapDistance = 0,
  }) => switch (part) {
    GizmoPart.move => _move(pointer, moveSnapDistance),
    GizmoPart.resize => _resize(pointer),
    GizmoPart.rotate => (
      x: null,
      y: null,
      scale: null,
      rotation: _rotate(pointer, snap),
    ),
    GizmoPart.none => (x: null, y: null, scale: null, rotation: null),
  };

  GizmoTransform _move(Offset pointer, double snapDistance) {
    final delta = pointer - grab;
    var x = restingX + delta.dx;
    var y = restingY + delta.dy;
    snapVerticals = const [];
    snapHorizontals = const [];

    if (snapDistance > 0 && canvasSize.width > 0 && canvasSize.height > 0) {
      final cx = canvasSize.width / 2;
      final cy = canvasSize.height / 2;
      final w = unitRect.width * drawnScale / 100;
      final h = unitRect.height * drawnScale / 100;
      final bounds = rotatedBounds(
        Rect.fromCenter(center: Offset(cx + x, cy + y), width: w, height: h),
        rotation,
      );

      final xTargets = <double>[0, cx, canvasSize.width];
      final yTargets = <double>[0, cy, canvasSize.height];
      for (final (rect, rot) in companions) {
        final b = rotatedBounds(rect, rot);
        xTargets.addAll([b.left, b.center.dx, b.right]);
        yTargets.addAll([b.top, b.center.dy, b.bottom]);
      }

      double? bestXDelta;
      var bestXDist = snapDistance;
      double? guideX;
      for (final candidate in [bounds.left, bounds.center.dx, bounds.right]) {
        for (final target in xTargets) {
          final dist = (candidate - target).abs();
          if (dist <= bestXDist) {
            bestXDist = dist;
            bestXDelta = target - candidate;
            guideX = target;
          }
        }
      }
      if (bestXDelta != null) {
        x += bestXDelta;
        snapVerticals = [guideX!];
      }

      double? bestYDelta;
      var bestYDist = snapDistance;
      double? guideY;
      for (final candidate in [bounds.top, bounds.center.dy, bounds.bottom]) {
        for (final target in yTargets) {
          final dist = (candidate - target).abs();
          if (dist <= bestYDist) {
            bestYDist = dist;
            bestYDelta = target - candidate;
            guideY = target;
          }
        }
      }
      if (bestYDelta != null) {
        y += bestYDelta;
        snapHorizontals = [guideY!];
      }
    }

    return (x: x, y: y, scale: null, rotation: null);
  }

  /// Uniform resize pinning the opposite handle. Ratios are measured in the
  /// rect's unrotated frame so a rotated image resizes along its own edges;
  /// corners take the larger of the two axis ratios so the drag tracks the
  /// pointer instead of lagging on one axis.
  GizmoTransform _resize(Offset pointer) {
    const none = (x: null, y: null, scale: null, rotation: null);
    if (unitRect.width <= 0 || unitRect.height <= 0) return none;

    final from = rotatePoint(grab, centre, -rotation);
    final to = rotatePoint(pointer, centre, -rotation);
    final controlsX = handle != 1 && handle != 7;
    final controlsY = handle != 3 && handle != 5;
    final ratios = <double>[
      if (controlsX && (from.dx - _fixedUnrotated.dx).abs() > 1e-6)
        (to.dx - _fixedUnrotated.dx) / (from.dx - _fixedUnrotated.dx),
      if (controlsY && (from.dy - _fixedUnrotated.dy).abs() > 1e-6)
        (to.dy - _fixedUnrotated.dy) / (from.dy - _fixedUnrotated.dy),
    ];
    if (ratios.isEmpty) return none;
    final ratio = ratios.map((r) => r.abs()).reduce(math.max);
    // Multiplicative, so a resize composes with a zoom or pop that scales the
    // resting value rather than replacing it.
    final scale = (restingScale * ratio).clamp(minScale, maxScale).toDouble();
    if (symmetric) {
      return (x: null, y: null, scale: scale, rotation: null);
    }

    // The pinned point lives on the *drawn* rect, so its arm is sized from the
    // drawn scale rather than from the resting scale the write targets.
    final drawn = drawnScale * ratio;
    final direction = gizmoAnchorDirection(8 - handle);
    final arm = rotatePoint(
      Offset(
        direction.dx * unitRect.width * drawn / 200,
        direction.dy * unitRect.height * drawn / 200,
      ),
      Offset.zero,
      rotation,
    );
    // Shift x/y by how far the centre had to travel rather than to an absolute
    // position: a delta survives a generated animation offsetting the clip.
    final move = (_fixedOnScreen - arm) - centre;
    return (
      x: restingX + move.dx,
      y: restingY + move.dy,
      scale: scale,
      rotation: null,
    );
  }

  double _rotate(Offset pointer, bool snap) {
    final angle = math.atan2(pointer.dy - centre.dy, pointer.dx - centre.dx);
    var degrees = rotation + (angle - _startAngle) * 180 / math.pi;
    if (snap) degrees = (degrees / 15).roundToDouble() * 15;
    // Stay inside the inspector slider's -180..180 range.
    return (degrees + 540) % 360 - 180;
  }
}

/// Axis-aligned bounding box of [rect] after it is rotated [degrees] clockwise
/// about its own centre — the footprint an image actually claims on the canvas,
/// which is what align/distribute reason about.
Rect rotatedBounds(Rect rect, double degrees) {
  if (degrees % 360 == 0) return rect;
  final centre = rect.center;
  final corners = [
    rotatePoint(rect.topLeft, centre, degrees),
    rotatePoint(rect.topRight, centre, degrees),
    rotatePoint(rect.bottomRight, centre, degrees),
    rotatePoint(rect.bottomLeft, centre, degrees),
  ];
  var left = corners.first.dx, right = corners.first.dx;
  var top = corners.first.dy, bottom = corners.first.dy;
  for (final p in corners.skip(1)) {
    left = math.min(left, p.dx);
    right = math.max(right, p.dx);
    top = math.min(top, p.dy);
    bottom = math.max(bottom, p.dy);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Which edge (or centre line) an align operation pulls items onto.
enum AlignEdge { left, centerX, right, top, centerY, bottom }

/// Axis a distribute operation spreads items along.
enum AlignAxis { horizontal, vertical }

/// Union of [bounds], or null when the list is empty.
Rect? boundsUnion(Iterable<Rect> bounds) {
  Rect? out;
  for (final b in bounds) {
    out = out == null ? b : out.expandToInclude(b);
  }
  return out;
}

/// Per-item translation that puts each of [bounds] against [edge] of [frame],
/// or of the union of [bounds] when [frame] is null. Same order as the input.
List<Offset> alignDeltas(List<Rect> bounds, AlignEdge edge, {Rect? frame}) {
  final target = frame ?? boundsUnion(bounds);
  if (target == null) return const [];
  return [
    for (final b in bounds)
      switch (edge) {
        AlignEdge.left => Offset(target.left - b.left, 0),
        AlignEdge.centerX => Offset(target.center.dx - b.center.dx, 0),
        AlignEdge.right => Offset(target.right - b.right, 0),
        AlignEdge.top => Offset(0, target.top - b.top),
        AlignEdge.centerY => Offset(0, target.center.dy - b.center.dy),
        AlignEdge.bottom => Offset(0, target.bottom - b.bottom),
      },
  ];
}

/// Per-item translation that equalises the gaps between [bounds] along [axis].
/// The two extreme items stay put; fewer than three items has nothing to
/// spread, so every delta is zero. A negative gap (items that overlap by more
/// than the span allows) is left as-is, which is the conventional result.
List<Offset> distributeDeltas(List<Rect> bounds, AlignAxis axis) {
  final zero = List<Offset>.filled(bounds.length, Offset.zero);
  if (bounds.length < 3) return zero;
  final horizontal = axis == AlignAxis.horizontal;
  double start(Rect r) => horizontal ? r.left : r.top;
  double extent(Rect r) => horizontal ? r.width : r.height;
  double centre(Rect r) => horizontal ? r.center.dx : r.center.dy;

  final union = boundsUnion(bounds)!;
  final order = List<int>.generate(bounds.length, (i) => i)
    ..sort((a, b) => centre(bounds[a]).compareTo(centre(bounds[b])));
  final occupied = bounds.fold<double>(0, (sum, b) => sum + extent(b));
  final gap = (extent(union) - occupied) / (bounds.length - 1);

  final out = List<Offset>.filled(bounds.length, Offset.zero);
  var cursor = horizontal ? union.left : union.top;
  for (final i in order) {
    final delta = cursor - start(bounds[i]);
    out[i] = horizontal ? Offset(delta, 0) : Offset(0, delta);
    cursor += extent(bounds[i]) + gap;
  }
  return out;
}

// --- Corner pin (TRK-20) -----------------------------------------------------
//
// Mirrors `unitSquareToQuad` / `invert3x3` / `rasterizeCornerPin` in
// `engine/render/composite.cpp`. The overlay's four draggable corners have to
// land on the pixels the engine warps to, so these must change together.

/// A 3x3 projective transform, row-major, acting on homogeneous points.
class Homography {
  const Homography(this.m);

  /// Maps the unit square (0,0),(1,0),(1,1),(0,1) onto [quad], given as eight
  /// numbers in TL/TR/BR/BL order. Null for a quad with no usable mapping.
  ///
  /// Heckbert's projective mapping, the same derivation the engine uses.
  static Homography? unitSquareToQuad(List<double> quad) {
    if (quad.length != 8 || quad.any((v) => !v.isFinite)) return null;
    final x0 = quad[0], y0 = quad[1], x1 = quad[2], y1 = quad[3];
    final x2 = quad[4], y2 = quad[5], x3 = quad[6], y3 = quad[7];
    final sx = x0 - x1 + x2 - x3;
    final sy = y0 - y1 + y2 - y3;
    double a, b, c, d, e, f, g, h;
    if (sx.abs() < 1e-12 && sy.abs() < 1e-12) {
      // Parallelogram: the projective terms vanish and this is plain affine.
      a = x1 - x0;
      b = x2 - x1;
      c = x0;
      d = y1 - y0;
      e = y2 - y1;
      f = y0;
      g = 0.0;
      h = 0.0;
    } else {
      final dx1 = x1 - x2, dx2 = x3 - x2;
      final dy1 = y1 - y2, dy2 = y3 - y2;
      final den = dx1 * dy2 - dx2 * dy1;
      if (den.abs() < 1e-12) return null;
      g = (sx * dy2 - dx2 * sy) / den;
      h = (dx1 * sy - sx * dy1) / den;
      a = x1 - x0 + g * x1;
      b = x3 - x0 + h * x3;
      c = x0;
      d = y1 - y0 + g * y1;
      e = y3 - y0 + h * y3;
      f = y0;
    }
    return Homography([a, b, c, d, e, f, g, h, 1.0]);
  }

  final List<double> m;

  Homography? get inverse {
    final c0 = m[4] * m[8] - m[5] * m[7];
    final c1 = m[5] * m[6] - m[3] * m[8];
    final c2 = m[3] * m[7] - m[4] * m[6];
    final det = m[0] * c0 + m[1] * c1 + m[2] * c2;
    if (!det.isFinite || det.abs() < 1e-12) return null;
    final inv = 1.0 / det;
    return Homography([
      c0 * inv,
      (m[2] * m[7] - m[1] * m[8]) * inv,
      (m[1] * m[5] - m[2] * m[4]) * inv,
      c1 * inv,
      (m[0] * m[8] - m[2] * m[6]) * inv,
      (m[2] * m[3] - m[0] * m[5]) * inv,
      c2 * inv,
      (m[1] * m[6] - m[0] * m[7]) * inv,
      (m[0] * m[4] - m[1] * m[3]) * inv,
    ]);
  }

  /// Applies the map, returning null for a point on the horizon (w == 0), which
  /// has no finite image.
  Offset? apply(Offset p) {
    final w = m[6] * p.dx + m[7] * p.dy + m[8];
    if (w.abs() < 1e-12) return null;
    return Offset(
      (m[0] * p.dx + m[1] * p.dy + m[2]) / w,
      (m[3] * p.dx + m[4] * p.dy + m[5]) / w,
    );
  }
}

/// Maps [quad] back into the unit square, so a pointer position can be tested
/// against, or expressed in, the pinned overlay's own space.
Homography? quadToUnitSquare(List<double> quad) =>
    Homography.unitSquareToQuad(quad)?.inverse;

/// The quad's corners as points, TL/TR/BR/BL — the overlay's drag handles.
List<Offset> quadCorners(List<double> quad) => [
  for (var i = 0; i < 4; i += 1) Offset(quad[2 * i], quad[2 * i + 1]),
];

List<double> quadFromCorners(List<Offset> corners) => [
  for (final c in corners) ...[c.dx, c.dy],
];

/// Axis-aligned bounds of a quad — the region the engine's warp can write to.
Rect quadBounds(List<double> quad) {
  final xs = [for (var i = 0; i < 4; i += 1) quad[2 * i]];
  final ys = [for (var i = 0; i < 4; i += 1) quad[2 * i + 1]];
  return Rect.fromLTRB(
    xs.reduce(math.min),
    ys.reduce(math.min),
    xs.reduce(math.max),
    ys.reduce(math.max),
  );
}

/// True when [point] falls inside [quad]. Uses the same convex winding test
/// the engine's `quadIsUsable` relies on, so hit-testing agrees with what is
/// actually painted.
bool quadContains(List<double> quad, Offset point) {
  var sign = 0;
  for (var i = 0; i < 4; i += 1) {
    final j = (i + 1) % 4;
    final ax = quad[2 * j] - quad[2 * i];
    final ay = quad[2 * j + 1] - quad[2 * i + 1];
    final bx = point.dx - quad[2 * i];
    final by = point.dy - quad[2 * i + 1];
    final cross = ax * by - ay * bx;
    if (cross == 0.0) continue;
    final s = cross > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return sign != 0;
}

/// The quad a clip's plain (unpinned) layer rect occupies, so pinning an
/// overlay can start from exactly where it already sits and never jump
/// (**TRK-19**).
List<double> quadFromRotatedRect(Rect rect, {double rotationDegrees = 0}) {
  final corners = [
    rect.topLeft,
    rect.topRight,
    rect.bottomRight,
    rect.bottomLeft,
  ];
  if (rotationDegrees == 0) return quadFromCorners(corners);
  final centre = rect.center;
  return quadFromCorners([
    for (final c in corners) rotatePoint(c, centre, rotationDegrees),
  ]);
}
