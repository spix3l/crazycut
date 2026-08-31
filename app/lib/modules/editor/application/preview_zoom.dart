part of 'editor_controller.dart';

/// UIX 3.2 monitor zoom control.
enum PreviewZoom {
  fit,
  pct25,
  pct50,
  pct100;

  String get label => switch (this) {
    PreviewZoom.fit => 'Fit',
    PreviewZoom.pct25 => '25%',
    PreviewZoom.pct50 => '50%',
    PreviewZoom.pct100 => '100%',
  };

  /// Fraction of sequence resolution shown on screen. Unused for [fit].
  double get scale => switch (this) {
    PreviewZoom.fit => 1,
    PreviewZoom.pct25 => 0.25,
    PreviewZoom.pct50 => 0.5,
    PreviewZoom.pct100 => 1,
  };
}
