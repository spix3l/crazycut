part of 'canvas_geometry.dart';

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
