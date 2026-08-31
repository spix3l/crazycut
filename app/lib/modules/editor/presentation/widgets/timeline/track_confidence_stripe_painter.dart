part of 'timeline_clip_tile.dart';

/// Spans where an area-tracking solve fell below its confidence threshold
/// (**TRK-8**).
///
/// A drifting track is otherwise only findable by watching the whole clip: the
/// solve reports a number per frame and nothing surfaced it. These say where to
/// look, in the one place the user is already scanning for what a clip does.
class TrackConfidenceStripePainter extends CustomPainter {
  const TrackConfidenceStripePainter({
    required this.spans,
    required this.pxPerSec,
  });

  /// Clip-local `(start, end)` seconds, one per weak span.
  final List<(double, double)> spans;

  final double pxPerSec;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = CcColors.warning;
    for (final (start, end) in spans) {
      final left = start * pxPerSec;
      // A single weak frame is a hairline at any sensible zoom, so give every
      // span a floor — the point is to be findable, not to be to scale.
      final width = math.max(2.0, (end - start) * pxPerSec);
      if (left > size.width || left + width < 0) continue;
      canvas.drawRect(Rect.fromLTWH(left, 0, width, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(TrackConfidenceStripePainter old) =>
      old.pxPerSec != pxPerSec || !listEquals(old.spans, spans);
}
