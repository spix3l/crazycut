part of 'project.dart';

/// Track row heights offered by the header menu (TIM-2).
enum TrackHeight {
  small(48),
  medium(72),
  large(104);

  const TrackHeight(this.pixels);
  final double pixels;

  static TrackHeight nearest(int pixels) {
    var best = TrackHeight.medium;
    var delta = double.infinity;
    for (final h in TrackHeight.values) {
      final d = (h.pixels - pixels).abs();
      if (d < delta) {
        delta = d;
        best = h;
      }
    }
    return best;
  }
}
