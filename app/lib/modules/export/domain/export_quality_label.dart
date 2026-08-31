part of 'export_presets.dart';

extension ExportQualityLabel on ExportQuality {
  String get label => switch (this) {
    ExportQuality.draft => 'Draft',
    ExportQuality.web => 'Web',
    ExportQuality.high => 'High',
    ExportQuality.master => 'Master',
  };

  /// x264/x265 CRF for this rung. Lower is better quality.
  int get crf => switch (this) {
    ExportQuality.draft => 28,
    ExportQuality.web => 23,
    ExportQuality.high => 19,
    ExportQuality.master => 16,
  };

  /// x264/x265 speed preset.
  String get preset => switch (this) {
    ExportQuality.draft => 'veryfast',
    ExportQuality.web => 'fast',
    ExportQuality.high => 'medium',
    ExportQuality.master => 'slow',
  };
}
