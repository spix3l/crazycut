part of 'timeline_edits.dart';

/// Snapshot of a clip's timing at the start of a gesture, so every update
/// during the drag is computed from the origin rather than from the last
/// frame's result (no drift, no double-snapping).
class ClipTiming {
  ClipTiming(this.trackId, this.start, this.duration, this.sourceIn);

  factory ClipTiming.of(Clip c) =>
      ClipTiming(c.trackId, c.start, c.duration, c.sourceIn);

  final String trackId;
  final Rt start;
  final Rt duration;
  final Rt sourceIn;

  Rt get end => start.plus(duration);
}

class _Gesture {
  _Gesture(
    this.kind,
    this.primaryId,
    this.origins,
    this.trackOrder, {
    this.breakLinks = false,
  });

  final EditGesture kind;
  final String primaryId;
  final Map<String, ClipTiming> origins;
  final List<String> trackOrder;
  final bool breakLinks;
}
