import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../data/project.dart';

/// Presentation grouping for the three asset families the pool and the
/// timeline draw differently.
enum MediaKind { video, audio, image }

MediaKind mediaKindOf(String type) => switch (type) {
      'audio' => MediaKind.audio,
      'image' => MediaKind.image,
      _ => MediaKind.video,
    };

extension MediaKindStyle on MediaKind {
  IconData get icon => switch (this) {
        MediaKind.video => LucideIcons.film,
        MediaKind.audio => LucideIcons.audioWaveform,
        MediaKind.image => LucideIcons.image,
      };

  Gradient get plate => switch (this) {
        MediaKind.video => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [CcColors.videoPlate2, CcColors.videoPlate],
          ),
        MediaKind.audio => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2C5A47), CcColors.audioPlate],
          ),
        MediaKind.image => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF7A6A4E), Color(0xFF3A3227)],
          ),
      };
}

extension AssetPresentation on MediaAsset {
  MediaKind get kind => mediaKindOf(type);

  /// Metadata line under the name in the pool.
  String get metaLine {
    if (offline) return 'Offline · relink needed';
    final parts = <String>[
      if (kind == MediaKind.video && width != null && height != null) '$width×$height',
      if (kind == MediaKind.audio) 'Audio · ${(48000 / 1000).round()}kHz',
      if (codec != null) codec!.toUpperCase(),
      if (vfr) 'VFR',
      if (hdr != 'none') hdr.toUpperCase(),
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }
}

/// Zoom bounds: 8 px/s (≈3 minutes across a 1440 px viewport) up to 160 px/s
/// (about 5 px per frame at 30 fps).
const double kPixelsPerSecond = 40;
const double kMinPxPerSec = 8;
const double kMaxPxPerSec = 160;

/// Above this zoom a video clip is wide enough to be worth a filmstrip.
const double kFilmstripMinPxPerSec = 24;

String formatDuration(double seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
