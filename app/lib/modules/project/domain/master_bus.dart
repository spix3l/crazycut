part of 'project.dart';

/// Master output bus (AUD-10/11). The limiter is on by default: it exists to
/// stop an accidental over reaching the file, not to shape the mix.
class MasterBus {
  MasterBus({this.gain = 1.0, this.limiter = true, this.ceilingDb = -1.0});

  double gain;
  bool limiter;
  double ceilingDb;

  MasterBus copy() =>
      MasterBus(gain: gain, limiter: limiter, ceilingDb: ceilingDb);

  Map<String, dynamic> toJson() => {
    'gain': gain,
    'limiter': limiter,
    'ceilingDb': ceilingDb,
  };

  static MasterBus fromJson(Map<String, dynamic>? j) => MasterBus(
    gain: (j?['gain'] as num?)?.toDouble() ?? 1.0,
    limiter: (j?['limiter'] as bool?) ?? true,
    ceilingDb: (j?['ceilingDb'] as num?)?.toDouble() ?? -1.0,
  );
}
