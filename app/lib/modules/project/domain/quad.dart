part of 'area_track.dart';

/// A quad in TL/TR/BR/BL order, flattened to 8 numbers.
typedef Quad = List<double>;

/// Numbers below this are treated as noise when comparing quads.
const double kQuadEpsilon = 1e-6;

Quad quadFromRect({
  required double left,
  required double top,
  required double right,
  required double bottom,
}) => [left, top, right, top, right, bottom, left, bottom];

/// Centre of a quad — the mean of its corners, which is the projective centre
/// only for a parallelogram but is what every pin mode uses as its anchor.
({double x, double y}) quadCentre(Quad q) {
  var x = 0.0, y = 0.0;
  for (var i = 0; i < 4; i += 1) {
    x += q[2 * i];
    y += q[2 * i + 1];
  }
  return (x: x / 4, y: y / 4);
}

/// Twice the signed area (the shoelace sum). Sign tells winding; magnitude is
/// what [quadIsUsable] thresholds on.
double quadTwiceArea(Quad q) {
  var acc = 0.0;
  for (var i = 0; i < 4; i += 1) {
    final j = (i + 1) % 4;
    acc += q[2 * i] * q[2 * j + 1] - q[2 * j] * q[2 * i + 1];
  }
  return acc;
}

/// Mirrors `quadIsUsable` in engine `render/composite.cpp`: simple, convex, and
/// at least a pixel of area. A planar rectangle seen through any real camera
/// projects to a convex quad, so anything else is a degenerate solve and the
/// compositor renders nothing for it (**TRK-25**).
bool quadIsUsable(Quad q) {
  if (q.length != 8 || q.any((v) => !v.isFinite)) return false;
  var sign = 0;
  for (var i = 0; i < 4; i += 1) {
    final j = (i + 1) % 4, k = (i + 2) % 4;
    final ax = q[2 * j] - q[2 * i], ay = q[2 * j + 1] - q[2 * i + 1];
    final bx = q[2 * k] - q[2 * j], by = q[2 * k + 1] - q[2 * j + 1];
    final cross = ax * by - ay * bx;
    if (!cross.isFinite || cross == 0.0) return false;
    final s = cross > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return quadTwiceArea(q).abs() >= 2.0;
}
