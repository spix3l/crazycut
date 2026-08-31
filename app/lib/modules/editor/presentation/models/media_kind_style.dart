part of 'editor_models.dart';

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
