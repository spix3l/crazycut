part of 'export_service.dart';

enum CaptionSidecarFormat { none, srt, webVtt }

/// Clips a sidecar to the exported in/out range and rebases it to output zero.
/// Burn-in continues to use absolute sequence time in the worker snapshot.
CaptionTrack captionSidecarTrack(
  CaptionTrack source, {
  required double startSeconds,
  required double endSeconds,
}) {
  final track = source.copy();
  track.items.removeWhere((item) {
    final start = item.start.seconds;
    final end = item.end.seconds;
    return end <= startSeconds || start >= endSeconds;
  });
  for (final item in track.items) {
    final clippedStart = math.max(item.start.seconds, startSeconds);
    final clippedEnd = math.min(item.end.seconds, endSeconds);
    item.start = Rt.fromSeconds(clippedStart - startSeconds);
    item.duration = Rt.fromSeconds(clippedEnd - clippedStart);
    item.words.removeWhere(
      (word) =>
          word.end.seconds <= startSeconds || word.start.seconds >= endSeconds,
    );
    for (final word in item.words) {
      word.start = Rt.fromSeconds(
        math.max(word.start.seconds, startSeconds) - startSeconds,
      );
      word.end = Rt.fromSeconds(
        math.min(word.end.seconds, endSeconds) - startSeconds,
      );
    }
  }
  return track;
}
