part of 'timeline_edits.dart';

/// One keyframe on a clip, tagged with the parameter it animates.
///
/// [effectInstanceId] is `'__transform'` for the built-in transform, matching
/// the id the keyframe operations take.
class ClipKeyframe {
  const ClipKeyframe({
    required this.effectInstanceId,
    required this.paramId,
    required this.time,
    required this.label,
    required this.generated,
  });

  final String effectInstanceId;
  final String paramId;

  /// Clip-local time.
  final Rt time;

  /// What to call this parameter in a menu ("Scale", "Blur · Radius").
  final String label;

  /// Written by a clip-animation preset rather than by hand. Deleting one is
  /// pointless: the next spec rebuild puts it straight back, so the UI offers
  /// to clear the preset instead.
  final bool generated;
}
