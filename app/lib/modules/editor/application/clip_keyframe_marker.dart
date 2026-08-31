part of 'timeline_edits.dart';

/// All the keyframes sharing one instant on a clip — what a single diamond on
/// the timeline stands for.
class ClipKeyframeMarker {
  const ClipKeyframeMarker({required this.time, required this.keys});

  final Rt time;
  final List<ClipKeyframe> keys;

  bool get allGenerated => keys.every((k) => k.generated);
  bool get anyGenerated => keys.any((k) => k.generated);
}
