/// Geometry shared by the on-canvas transform gizmo and the C++ compositor.
///
/// Every function here mirrors `engine/render/composite.cpp rasterizeLayer()`.
/// The gizmo has to draw the *same* rectangle the engine rasterises, so if that
/// function's framing/anchor maths ever changes, change these with it.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

part 'align_axis.dart';
part 'align_edge.dart';
part 'gizmo_drag.dart';
part 'gizmo_part.dart';
part 'gizmo_transform.dart';
part 'homography.dart';

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
