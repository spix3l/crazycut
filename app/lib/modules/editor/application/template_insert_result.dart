part of 'template_edits.dart';

/// What an insert produced, plus everything it had to work around (TPL-9/13).
class TemplateInsertResult {
  const TemplateInsertResult({
    required this.clipIds,
    required this.warnings,
    this.edgeInId,
    this.edgeOutId,
  });

  final List<String> clipIds;

  /// Non-fatal: an edge with no handles, a clamped duration, offline media.
  /// The insert completed regardless (TPL-9).
  final List<String> warnings;

  final String? edgeInId;
  final String? edgeOutId;

  bool get isEmpty => clipIds.isEmpty;
}
