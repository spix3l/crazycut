/// Geometry shared by the on-canvas transform gizmo and the C++ compositor.
///
/// Every function here mirrors `engine/render/composite.cpp rasterizeLayer()`.
/// The gizmo has to draw the *same* rectangle the engine rasterises, so if that
/// function's framing/anchor maths ever changes, change these with it.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

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

  final Offset _fixedUnrotated;
  final Offset _fixedOnScreen;
  final double _startAngle;

  /// The transform [pointer] resolves to. [snap] rounds rotation to 15°.
  GizmoTransform resolve(Offset pointer, {bool snap = false}) => switch (part) {
    GizmoPart.move => _move(pointer),
    GizmoPart.resize => _resize(pointer),
    GizmoPart.rotate => (
      x: null,
      y: null,
      scale: null,
      rotation: _rotate(pointer, snap),
    ),
    GizmoPart.none => (x: null, y: null, scale: null, rotation: null),
  };

  GizmoTransform _move(Offset pointer) {
    final delta = pointer - grab;
    return (
      x: restingX + delta.dx,
      y: restingY + delta.dy,
      scale: null,
      rotation: null,
    );
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
