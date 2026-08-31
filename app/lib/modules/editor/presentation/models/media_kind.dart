part of 'editor_models.dart';

/// Presentation grouping for the three asset families the pool and the
/// timeline draw differently.
enum MediaKind { video, audio, image }

MediaKind mediaKindOf(String type) => switch (type) {
  'audio' => MediaKind.audio,
  'image' => MediaKind.image,
  _ => MediaKind.video,
};
