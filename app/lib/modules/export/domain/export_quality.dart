part of 'export_presets.dart';

/// Where the quality slider sits (EXP-4). One control the whole way; the
/// advanced panel edits the numbers it implies.
enum ExportQuality { draft, web, high, master }

/// Estimates final encoded bytes from the settings the worker actually uses.
/// Software CRF output is content-dependent; these rates are calibrated to
/// ordinary edited footage rather than a worst-case fixed-bitrate stream.
int estimateExportBytes({
  required ExportPreset preset,
  required ExportQuality quality,
  required int width,
  required int height,
  required double fps,
  required double seconds,
  bool hardware = false,
}) {
  if (width <= 0 || height <= 0 || fps <= 0 || seconds <= 0) return 0;

  double videoBitsPerPixel;
  if (preset.videoCodec == 'prores') {
    // ProRes 422 Standard is intraframe and much less content-dependent.
    videoBitsPerPixel = 2.35;
  } else if (hardware) {
    // Mirrors the bitrate mapping in timeline_job.cpp.
    videoBitsPerPixel = switch (quality.crf) {
      <= 18 => 0.20,
      <= 20 => 0.14,
      <= 23 => 0.10,
      _ => 0.06,
    };
  } else {
    videoBitsPerPixel = switch (quality) {
      ExportQuality.draft => 0.014,
      ExportQuality.web => 0.024,
      ExportQuality.high => 0.038,
      ExportQuality.master => 0.060,
    };
    if (preset.videoCodec == 'h265' || preset.videoCodec == 'hevc') {
      videoBitsPerPixel *= 0.7;
    }
  }

  final videoBits = width * height * fps * videoBitsPerPixel;
  final audioBits =
      preset.audioCodec == 'pcm' ? 48000 * 24 * 2 : preset.audioBitrate;
  // Allow a small amount for mux/container overhead.
  return (((videoBits + audioBits) / 8) * seconds * 1.015).round();
}
