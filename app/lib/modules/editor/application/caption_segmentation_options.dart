part of 'caption_segmentation.dart';

class CaptionSegmentationOptions {
  const CaptionSegmentationOptions({
    this.maxCharactersPerLine = 42,
    this.maxLines = 2,
    this.minDurationSeconds = 0.8,
    this.maxDurationSeconds = 6,
    this.maxCharactersPerSecond = 20,
    this.silenceBreakSeconds = 0.65,
    this.sequenceOffset = const Duration(),
  }) : assert(maxCharactersPerLine > 0),
       assert(maxLines > 0),
       assert(minDurationSeconds > 0),
       assert(maxDurationSeconds >= minDurationSeconds),
       assert(maxCharactersPerSecond > 0),
       assert(silenceBreakSeconds >= 0);

  final int maxCharactersPerLine;
  final int maxLines;
  final double minDurationSeconds;
  final double maxDurationSeconds;
  final double maxCharactersPerSecond;
  final double silenceBreakSeconds;
  final Duration sequenceOffset;

  int get maxCharacters => maxCharactersPerLine * maxLines;
}
