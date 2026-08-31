part of 'project.dart';

class Fade {
  Fade({Rt? duration, this.curve = 'linear'})
    : duration = duration ?? Rt.zero();

  Rt duration;
  String curve;

  Fade copy() => Fade(duration: duration, curve: curve);

  Map<String, dynamic> toJson() => {
    'duration': duration.toString(),
    'curve': curve,
  };

  static Fade fromJson(Map<String, dynamic>? j) => Fade(
    duration:
        j?['duration'] == null ? Rt.zero() : Rt.parse(j!['duration'] as String),
    curve: (j?['curve'] as String?) ?? 'linear',
  );
}
