part of 'editor_models.dart';

extension AssetPresentation on MediaAsset {
  MediaKind get kind => mediaKindOf(type);

  /// Metadata line under the name in the pool.
  String get metaLine {
    if (offline) {
      return isRemote
          ? 'Remote unavailable · retry'
          : 'Offline · relink needed';
    }
    final parts = <String>[
      if (isRemote) 'URL',
      if (kind == MediaKind.video && width != null && height != null)
        '$width×$height',
      if (kind == MediaKind.audio) 'Audio · ${(48000 / 1000).round()}kHz',
      if (codec != null) codec!.toUpperCase(),
      if (vfr) 'VFR',
      if (hdr != 'none') hdr.toUpperCase(),
    ];
    return parts.isEmpty ? 'None' : parts.join(' · ');
  }
}

/// Zoom bounds: 8 px/s (≈3 minutes across a 1440 px viewport) up to 160 px/s
/// (about 5 px per frame at 30 fps).
const double kPixelsPerSecond = 40;
const double kMinPxPerSec = 8;
const double kMaxPxPerSec = 160;

/// Maps the timeline's normalized control position onto its exponential zoom
/// range. Keeping this and [timelineZoomForPixelsPerSecond] together prevents
/// toolbar clicks and the screen from interpreting the same value differently.
double timelinePixelsPerSecondForZoom(double zoom) {
  final t = zoom.clamp(0.0, 1.0);
  return (kMinPxPerSec * math.pow(kMaxPxPerSec / kMinPxPerSec, t)).toDouble();
}

/// Inverse of [timelinePixelsPerSecondForZoom].
double timelineZoomForPixelsPerSecond(double pixelsPerSecond) {
  final pixels = pixelsPerSecond.clamp(kMinPxPerSec, kMaxPxPerSec);
  final ratio = pixels / kMinPxPerSec;
  final span = kMaxPxPerSec / kMinPxPerSec;
  return (math.log(ratio) / math.log(span)).clamp(0.0, 1.0).toDouble();
}

/// Lane scale as the timeline zooms out. At the default zoom lanes sit at
/// their authored [TrackHeight]; zooming out shrinks them down to half so
/// more tracks fit on screen. Zooming in keeps them full size — the authored
/// height stays the ceiling, and only the horizontal scale grows.
double timelineLaneScaleForPixelsPerSecond(double pxPerSec) {
  if (pxPerSec >= kPixelsPerSecond) return 1.0;
  final t = ((pxPerSec - kMinPxPerSec) / (kPixelsPerSecond - kMinPxPerSec))
      .clamp(0.0, 1.0);
  return 0.5 + 0.5 * t;
}

String formatDuration(double seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
