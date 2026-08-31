part of 'area_track.dart';

/// A clip's pin to a tracker.
class TrackPin {
  TrackPin({
    required this.trackerId,
    this.mode = PinMode.cornerPin,
    Quad? offset,
  }) : offset = offset ?? const [0, 0, 0, 0, 0, 0, 0, 0];

  /// Quarantine-not-throw: anything unreadable yields null rather than throwing,
  /// and the clip simply is not pinned.
  static TrackPin? fromExtra(Map<String, dynamic>? extra) {
    final raw = extra?[kTrackPinKey];
    if (raw is! Map) return null;
    final id = raw['trackerId'];
    if (id is! String || id.isEmpty) return null;
    return TrackPin(
      trackerId: id,
      mode: PinMode.parse(raw['mode'] as String?),
      offset: _quad(raw['offset']),
    );
  }

  final String trackerId;
  final PinMode mode;

  /// Per-corner offset in sequence px, captured when the clip was pinned so the
  /// overlay never jumps, and preserved when the user nudges it (**TRK-19**).
  final Quad offset;

  Map<String, dynamic> toJson() => {
    'trackerId': trackerId,
    'mode': mode.id,
    if (offset.any((v) => v.abs() > kQuadEpsilon)) 'offset': offset,
  };

  TrackPin copyWith({PinMode? mode, Quad? offset}) => TrackPin(
    trackerId: trackerId,
    mode: mode ?? this.mode,
    offset: offset ?? this.offset,
  );
}
