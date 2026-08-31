part of 'media_pool.dart';

extension MediaPoolFilterPresentation on MediaPoolFilter {
  String get label => switch (this) {
    MediaPoolFilter.all => 'All',
    MediaPoolFilter.videos => 'Videos',
    MediaPoolFilter.audios => 'Audios',
    MediaPoolFilter.images => 'Images',
  };

  MediaKind? get kind => switch (this) {
    MediaPoolFilter.all => null,
    MediaPoolFilter.videos => MediaKind.video,
    MediaPoolFilter.audios => MediaKind.audio,
    MediaPoolFilter.images => MediaKind.image,
  };
}
