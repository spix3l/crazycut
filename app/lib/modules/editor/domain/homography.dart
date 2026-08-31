part of 'canvas_geometry.dart';

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
