part of 'media_relink.dart';

class RelinkMatch {
  const RelinkMatch({
    required this.assetId,
    required this.assetName,
    required this.path,
    required this.confidence,
  });

  final String assetId;
  final String assetName;
  final String path;
  final RelinkConfidence confidence;
}
