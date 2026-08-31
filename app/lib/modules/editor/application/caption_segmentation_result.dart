part of 'caption_segmentation.dart';

class CaptionSegmentationResult {
  const CaptionSegmentationResult({
    required this.track,
    this.issues = const [],
  });

  final CaptionTrack track;
  final List<CaptionIssue> issues;
}
