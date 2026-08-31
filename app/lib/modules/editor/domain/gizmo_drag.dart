part of 'canvas_geometry.dart';

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
