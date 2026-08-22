import 'package:crazycut_app/data/project.dart';

/// Where the quality slider sits (EXP-4). One control the whole way; the
/// advanced panel edits the numbers it implies.
enum ExportQuality { draft, web, high, master }

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

/// A delivery target from the EXP-2 preset table.
class ExportPreset {
  const ExportPreset({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.container,
    required this.videoCodec,
    required this.audioCodec,
    required this.quality,
    this.audioBitrate = 320000,
    this.maxWidth = 0,
    this.maxHeight = 0,
    this.loudnessDefault = false,
    this.faststart = true,
    this.custom = false,
  });

  final String id;
  final String name;
  final String subtitle;

  /// File extension, without the dot.
  final String container;
  final String videoCodec;
  final String audioCodec;
  final ExportQuality quality;
  final int audioBitrate;

  /// 0 means "keep the sequence resolution" (EXP-3).
  final int maxWidth;
  final int maxHeight;

  /// Social presets default to loudness normalization (EXP-7).
  final bool loudnessDefault;
  final bool faststart;
  final bool custom;

  static const youtube1080 = ExportPreset(
    id: 'youtube1080',
    name: 'YouTube 1080p',
    subtitle: 'H.264 · AAC',
    container: 'mp4',
    videoCodec: 'h264',
    audioCodec: 'aac',
    quality: ExportQuality.high,
    maxWidth: 1920,
    maxHeight: 1080,
    loudnessDefault: true,
  );

  static const youtube4k = ExportPreset(
    id: 'youtube4k',
    name: 'YouTube 4K',
    subtitle: 'H.264 · AAC',
    container: 'mp4',
    videoCodec: 'h264',
    audioCodec: 'aac',
    quality: ExportQuality.high,
    maxWidth: 3840,
    maxHeight: 2160,
    loudnessDefault: true,
  );

  static const shorts = ExportPreset(
    id: 'shorts',
    name: 'Shorts/TikTok/Reels',
    subtitle: '1080×1920 · AAC',
    container: 'mp4',
    videoCodec: 'h264',
    audioCodec: 'aac',
    quality: ExportQuality.high,
    maxWidth: 1080,
    maxHeight: 1920,
    loudnessDefault: true,
  );

  static const instagram = ExportPreset(
    id: 'instagram',
    name: 'Instagram Feed',
    subtitle: '1080×1350 · AAC',
    container: 'mp4',
    videoCodec: 'h264',
    audioCodec: 'aac',
    quality: ExportQuality.high,
    maxWidth: 1080,
    maxHeight: 1350,
    loudnessDefault: true,
  );

  static const proresMaster = ExportPreset(
    id: 'prores',
    name: 'Master (ProRes)',
    subtitle: 'MOV · PCM 24-bit',
    container: 'mov',
    videoCodec: 'prores',
    audioCodec: 'pcm',
    quality: ExportQuality.master,
    faststart: false,
  );

  static const customPreset = ExportPreset(
    id: 'custom',
    name: 'Custom',
    subtitle: 'Set your own',
    container: 'mp4',
    videoCodec: 'h264',
    audioCodec: 'aac',
    quality: ExportQuality.high,
    custom: true,
  );

  static const all = [
    youtube1080,
    youtube4k,
    shorts,
    instagram,
    proresMaster,
    customPreset,
  ];

  static ExportPreset byId(String id) =>
      all.firstWhere((p) => p.id == id, orElse: () => youtube1080);

  /// The output size this preset produces for a given sequence: aspect is
  /// preserved and the sequence is never upscaled (EXP-3).
  (int, int) outputSize(SequenceSettings settings) {
    if (maxWidth <= 0 && maxHeight <= 0) {
      return (settings.width, settings.height);
    }
    final limitW = maxWidth > 0 ? maxWidth : settings.width;
    final limitH = maxHeight > 0 ? maxHeight : settings.height;
    final scale = [
      1.0,
      limitW / settings.width,
      limitH / settings.height,
    ].reduce((a, b) => a < b ? a : b);
    var w = (settings.width * scale).round();
    var h = (settings.height * scale).round();
    if (w.isOdd) w -= 1;
    if (h.isOdd) h -= 1;
    return (w, h);
  }

  /// Default filename: `<project> [<preset>].<ext>` (EXP-8).
  String defaultFilename(String projectName) =>
      '$projectName [$name].$container';
}
