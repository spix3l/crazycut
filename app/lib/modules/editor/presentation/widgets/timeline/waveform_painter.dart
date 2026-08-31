part of 'timeline_clip_tile.dart';

/// Bar waveform. With real [peaks] it renders the slice the clip uses; without
/// them it falls back to a deterministic pattern so the lane never looks empty.
class WaveformPainter extends CustomPainter {
  const WaveformPainter({
    this.seed = 0,
    this.color = CcColors.audioWave,
    this.peaks = const [],
    this.startFraction = 0,
    this.endFraction = 1,
  });

  final int seed;
  final Color color;
  final List<double> peaks;
  final double startFraction;
  final double endFraction;

  static const _pattern = [
    0.25,
    0.5,
    0.75,
    0.42,
    0.92,
    0.58,
    0.33,
    0.67,
    0.83,
    0.5,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const barWidth = 3.0;
    const step = 5.0;
    final columns = ((size.width - barWidth) / step).floor() + 1;
    var i = seed;
    var column = 0;
    for (var x = 0.0; x + barWidth <= size.width; x += step) {
      double amplitude;
      if (peaks.isEmpty) {
        amplitude = _pattern[i++ % _pattern.length];
      } else {
        final t = columns <= 1 ? 0.0 : column / (columns - 1);
        final fraction = startFraction + (endFraction - startFraction) * t;
        final index = (fraction * (peaks.length - 1)).round().clamp(
          0,
          peaks.length - 1,
        );
        amplitude = peaks[index];
      }
      column++;
      final barHeight = (size.height * amplitude).clamp(2.0, size.height);
      final top = (size.height - barHeight) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barWidth, barHeight),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) =>
      oldDelegate.seed != seed ||
      oldDelegate.color != color ||
      oldDelegate.peaks.length != peaks.length ||
      oldDelegate.startFraction != startFraction ||
      oldDelegate.endFraction != endFraction;
}
