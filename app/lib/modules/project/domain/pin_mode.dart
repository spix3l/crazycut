part of 'area_track.dart';

/// How much of a solved quad an overlay follows (**TRK-18**). All four are
/// decoded from the same homography; the simpler modes exist because they
/// discard the noisiest components of a solve.
enum PinMode {
  position,
  positionScale,
  positionScaleRotation,
  cornerPin;

  static PinMode parse(String? raw) => switch (raw) {
    'position' => PinMode.position,
    'positionScale' => PinMode.positionScale,
    'positionScaleRotation' => PinMode.positionScaleRotation,
    _ => PinMode.cornerPin,
  };

  String get id => name;
}
