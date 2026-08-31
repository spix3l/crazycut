part of 'caption_interchange.dart';

class CaptionImportOptions {
  const CaptionImportOptions({
    this.language = 'und',
    this.frameRate = 30,
    this.repairOverlaps = true,
  }) : assert(frameRate > 0);

  final String language;
  final double frameRate;
  final bool repairOverlaps;
}
