part of 'media_relink.dart';

/// What a relink pass found. Exact matches can be applied without asking;
/// proposed ones are shown for confirmation, and the rest stay offline.
class RelinkPlan {
  const RelinkPlan({required this.matches, required this.unmatched});

  final List<RelinkMatch> matches;
  final List<MediaAsset> unmatched;

  int get exactCount =>
      matches.where((m) => m.confidence == RelinkConfidence.exact).length;
  int get proposedCount =>
      matches.where((m) => m.confidence == RelinkConfidence.proposed).length;

  bool get isEmpty => matches.isEmpty;

  String get summary {
    final parts = <String>[];
    if (exactCount > 0) parts.add('$exactCount matched by content');
    if (proposedCount > 0) parts.add('$proposedCount matched by name');
    if (unmatched.isNotEmpty) parts.add('${unmatched.length} still missing');
    return parts.isEmpty ? 'Nothing to relink' : parts.join(' · ');
  }
}
