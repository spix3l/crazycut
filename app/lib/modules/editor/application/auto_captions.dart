import 'dart:math' as math;

import 'package:crazycut_app/modules/editor/application/caption_segmentation.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/project/domain/transcript.dart';
import 'package:crazycut_app/core/math/rational.dart';

/// The clip and media chosen for an automatic-caption run.
class AutoCaptionSource {
  const AutoCaptionSource({required this.clip, required this.asset});

  final Clip clip;
  final MediaAsset asset;
}

/// Picks the user's selected clip when it contains audio, then falls back to
/// the longest audible clip in the sequence. Text clips and muted clips are
/// not useful transcription sources.
AutoCaptionSource? chooseAutoCaptionSource(ProjectDoc doc, Clip? selected) {
  AutoCaptionSource? sourceFor(Clip clip) {
    if (clip.mediaId.isEmpty || clip.mute || clip.reverse) return null;
    final asset = doc.assetById(clip.mediaId);
    if (asset == null || !asset.hasAudio || asset.offline) return null;
    return AutoCaptionSource(clip: clip, asset: asset);
  }

  if (selected != null) {
    final chosen = sourceFor(selected);
    if (chosen != null) return chosen;
  }

  AutoCaptionSource? best;
  for (final clip in doc.clips) {
    final candidate = sourceFor(clip);
    if (candidate == null) continue;
    if (best == null || clip.duration > best.clip.duration) best = candidate;
  }
  return best;
}

/// Maps a media-time transcript through a clip's trim and speed into exact
/// sequence-time caption cues.
CaptionSegmentationResult captionsForClip(
  Transcript transcript,
  Clip clip, {
  String? trackId,
  String trackName = 'Auto captions',
}) {
  final sourceStart = clip.sourceIn.seconds;
  final sourceEnd = sourceStart + clip.sourceSpan.seconds;
  final speed = clip.speedValue.abs();
  final safeSpeed = speed <= 0 ? 1.0 : speed;
  final segments = <TranscriptSegment>[];

  for (final segment in transcript.segments) {
    final start = math.max(segment.start, sourceStart);
    final end = math.min(segment.end, sourceEnd);
    if (end <= start) continue;
    segments.add(
      TranscriptSegment(
        start: (start - sourceStart) / safeSpeed,
        end: (end - sourceStart) / safeSpeed,
        text: segment.text,
      ),
    );
  }

  final result = const CaptionSegmenter().convert(
    Transcript(
      language: transcript.language,
      durationSeconds: clip.duration.seconds,
      segments: segments,
    ),
    trackId: trackId,
    trackName: trackName,
    options: CaptionSegmentationOptions(
      sequenceOffset: Duration(microseconds: clip.start.micros),
    ),
  );
  for (final item in result.track.items) {
    if (item.end > clip.end) item.duration = clip.end.minus(item.start);
    for (final word in item.words) {
      word.start = word.start.clampTo(item.start, item.end);
      word.end = word.end.clampTo(word.start, item.end);
    }
  }
  result.track.items.removeWhere((item) => item.duration <= Rt.zero());
  return result;
}
