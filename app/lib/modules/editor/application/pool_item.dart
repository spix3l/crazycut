part of 'editor_controller.dart';

class PoolItem {
  PoolItem({
    required this.asset,
    this.status = ImportStatus.probing,
    this.thumb,
  });
  final MediaAsset asset;
  ImportStatus status;
  Uint8List? thumb;

  /// True while the URL source behind this item is being copied into the media
  /// cache (see [RemoteSourceCache]); the pool says so instead of leaving the
  /// card looking finished while seeks are still slow.
  bool caching = false;
}

/// The still-picture half of [kSupportedExtensions]. Anything offered as "an
/// image" — the tracked-region replacement, for one — filters on this rather
/// than on a list of its own, which is how that dialog came to offer formats
/// the importer then refused.
const kImageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'svg'};

/// Files we accept (IMP: supported formats).
const kSupportedExtensions = {
  'mp4',
  'mov',
  'mkv',
  'webm',
  'm4v',
  'mp3',
  'm4a',
  'aac',
  'wav',
  'flac',
  'ogg',
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'svg',
};
