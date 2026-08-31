part of 'caption_report.dart';

/// A user-presentable problem found while converting or importing captions.
class CaptionIssue {
  const CaptionIssue({
    required this.message,
    this.severity = CaptionIssueSeverity.warning,
    this.cueNumber,
    this.lineNumber,
    this.repaired = false,
  });

  final String message;
  final CaptionIssueSeverity severity;
  final int? cueNumber;
  final int? lineNumber;
  final bool repaired;
}
