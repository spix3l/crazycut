part of 'timeline_clip_tile.dart';

/// A diamond for each instant a clip has keyframes at (KEY-5).
///
/// Animation used to be invisible on the timeline: the only evidence that a
/// clip moved was the picture moving. These marks say where the keys are, and
/// the panel makes them clickable so one can be jumped to or deleted.
class KeyframeRibbonPainter extends CustomPainter {
  const KeyframeRibbonPainter({
    required this.seconds,
    required this.generated,
    required this.pxPerSec,
    this.highlightSeconds,
  });

  /// Clip-local seconds, one per marker.
  final List<double> seconds;

  /// Parallel to [seconds]: a preset owns this key, so it cannot be deleted
  /// on its own and is drawn hollow to say so.
  final List<bool> generated;

  final double pxPerSec;

  /// The marker under the playhead, drawn larger.
  final double? highlightSeconds;

  static const double _radius = 3.2;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0x66000000),
    );

    final fill = Paint()..color = CcColors.accent;
    final hollow =
        Paint()
          ..color = CcColors.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2;
    final cy = size.height / 2;

    for (var i = 0; i < seconds.length; i += 1) {
      final x = seconds[i] * pxPerSec;
      if (x < -_radius || x > size.width + _radius) continue;
      final current =
          highlightSeconds != null &&
          (seconds[i] - highlightSeconds!).abs() < 0.001;
      final r = current ? _radius + 1.2 : _radius;
      final path =
          Path()
            ..moveTo(x, cy - r)
            ..lineTo(x + r, cy)
            ..lineTo(x, cy + r)
            ..lineTo(x - r, cy)
            ..close();
      canvas.drawPath(path, generated[i] ? hollow : fill);
    }
  }

  @override
  bool shouldRepaint(KeyframeRibbonPainter old) =>
      old.pxPerSec != pxPerSec ||
      old.highlightSeconds != highlightSeconds ||
      !listEquals(old.seconds, seconds) ||
      !listEquals(old.generated, generated);
}
