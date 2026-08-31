/// Area tracking model (`docs/03-features/tracking.md`, **TRK**).
///
/// A [Tracker] is a solved motion path for a user-drawn region, stored in the
/// document rather than the media cache: it combines user-authored input (the
/// region, any corrections) with an expensive solve, so unlike thumbnails or
/// peaks it is not safe to delete and regenerate (**TRK-13**).
///
/// A [TrackPin] lives on the clip that follows a tracker, in `extra`, in the
/// same generated-spec style as `clipAnim` (**TXT-10**): the pose is *derived*
/// from the tracker on every evaluation and never copied into the clip.
library;

import 'package:crazycut_app/core/math/rational.dart';

part 'pin_mode.dart';
part 'quad.dart';
part 'track_pin.dart';
part 'tracker.dart';

const String kTrackPinKey = 'trackPin';
