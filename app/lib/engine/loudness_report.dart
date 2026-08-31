part of 'engine.dart';

class LoudnessReport {
  const LoudnessReport({
    required this.lufs,
    required this.peakDb,
    required this.truePeakDb,
  });

  final double lufs;
  final double peakDb;
  final double truePeakDb;
}
