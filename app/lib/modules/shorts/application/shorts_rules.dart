part of 'shorts_service.dart';

/// Bounds a candidate must satisfy to survive (SHT-6).
class ShortsRules {
  const ShortsRules({
    this.minSeconds = 5,
    this.maxSeconds = 180,
    this.maxCandidates = 12,
  });

  final double minSeconds;
  final double maxSeconds;
  final int maxCandidates;
}
