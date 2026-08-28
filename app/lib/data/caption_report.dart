enum CaptionIssueSeverity { warning, error }

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

typedef CaptionIdFactory = String Function();

CaptionIdFactory captionIdFactory([String prefix = 'caption']) {
  var next = 0;
  final seed = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  return () => '$prefix-$seed-${next++}';
}
