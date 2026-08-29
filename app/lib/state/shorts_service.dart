/// Shorts: proposal, sanitisation, and spawning 9:16 projects (SHT-*).
///
/// The model's only job is to *nominate* moments. Everything that decides what
/// actually gets created — bounds, minimum and maximum length, overlaps, the
/// cap on how many — is enforced here, because model output is never trusted
/// for geometry (SHT-6).
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:crazycut_app/ai/core/llm_message.dart';
import 'package:crazycut_app/ai/core/llm_provider.dart';
import 'package:crazycut_app/ai/core/schema_fallback.dart';
import 'package:crazycut_app/data/clip_transform.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/repository.dart';
import 'package:crazycut_app/data/transcript.dart';
import 'package:crazycut_app/models/rational.dart';

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

@immutable
class ShortCandidate {
  const ShortCandidate({
    required this.startSec,
    required this.endSec,
    required this.title,
    required this.hook,
    required this.reason,
    required this.confidence,
  });

  final double startSec;
  final double endSec;
  final String title;
  final String hook;
  final String reason;
  final double confidence;

  Map<String, dynamic> toJson() => {
    'startSec': startSec,
    'endSec': endSec,
    'title': title,
    'hook': hook,
    'reason': reason,
    'confidence': confidence,
  };

  double get durationSec => endSec - startSec;

  ShortCandidate copyWith({double? startSec, double? endSec, String? title}) =>
      ShortCandidate(
        startSec: startSec ?? this.startSec,
        endSec: endSec ?? this.endSec,
        title: title ?? this.title,
        hook: hook,
        reason: reason,
        confidence: confidence,
      );

  /// A coarse badge, not a number — confidence is a hint from a model, and
  /// showing "0.82" implies a measurement nobody took.
  String get confidenceLabel => switch (confidence) {
    >= 0.75 => 'Strong',
    >= 0.45 => 'Worth a look',
    _ => 'Long shot',
  };

  static ShortCandidate? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = (raw['startSec'] as num?)?.toDouble();
    final end = (raw['endSec'] as num?)?.toDouble();
    if (start == null || end == null) return null;
    return ShortCandidate(
      startSec: start,
      endSec: end,
      title: (raw['title'] as String? ?? '').trim(),
      hook: (raw['hook'] as String? ?? '').trim(),
      reason: (raw['reason'] as String? ?? '').trim(),
      confidence: ((raw['confidence'] as num?)?.toDouble() ?? 0.5).clamp(
        0.0,
        1.0,
      ),
    );
  }
}

/// The schema asked of the model. Numeric bounds are deliberately absent —
/// this subset of JSON Schema does not carry `minimum`/`maximum`, so the range
/// rules live in the prompt and are enforced in [sanitizeCandidates].
const shortsResponseSchema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'candidates': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'startSec': {'type': 'number'},
          'endSec': {'type': 'number'},
          'title': {'type': 'string'},
          'hook': {'type': 'string'},
          'reason': {'type': 'string'},
          'confidence': {'type': 'number'},
        },
        'required': ['startSec', 'endSec', 'title', 'hook', 'confidence'],
      },
    },
  },
  'required': ['candidates'],
};

class ShortsService {
  /// Bump when changing the selection rubric or response interpretation.
  static const promptVersion = 'shorts-rubric-v2';
  ShortsService({this.rules = const ShortsRules()});

  final ShortsRules rules;

  /// Asks [provider] to nominate moments in [transcript] (SHT-3, SHT-4).
  ///
  /// One request, not an agent loop: a whole transcript fits comfortably in a
  /// modern context window, so there is nothing to retrieve and a single call
  /// is cheaper and more predictable.
  Future<List<ShortCandidate>> propose(
    LlmProvider provider,
    Transcript transcript, {
    int wanted = 6,
    CancellationToken? cancel,
  }) async {
    if (transcript.isEmpty) return const [];

    final request = LlmRequest(
      messages: [
        LlmMessage.system(_systemPrompt(wanted)),
        LlmMessage.user(
          'Transcript of a ${_minutes(transcript.durationSeconds)} recording. '
          'Each line is one speech segment with its start and end.\n\n'
          '${transcript.toTimedText()}',
        ),
      ],
      maxTokens: 4096,
      reasoning: LlmReasoning.auto,
    );

    final decoded = await completeJson(
      provider,
      request,
      schema: shortsResponseSchema,
      cancel: cancel,
    );

    final raw = decoded is Map ? decoded['candidates'] : null;
    if (raw is! List) return const [];

    return sanitizeCandidates([
      for (final entry in raw) ?ShortCandidate.fromJson(entry),
    ], mediaDurationSec: transcript.durationSeconds, transcript: transcript);
  }

  String _systemPrompt(int wanted) =>
      'You are a senior short-form video editor selecting publishable clips '
      'from a long-form recording. Optimize for viewer retention and a '
      'complete idea, not for evenly spaced highlights.\n\n'
      'Return at most $wanted candidates, ranked best first. Be selective: '
      'return fewer candidates or an empty list when the material is weak. '
      'For each candidate:\n'
      '- Choose a self-contained story beat with a clear setup, tension or '
      'surprise, and payoff. It must make sense to a viewer with no context.\n'
      '- Prefer a strong first sentence, specific insight, emotional turn, '
      'controversial claim, concrete result, or useful takeaway.\n'
      '- Reject greetings, housekeeping, sponsorships, filler, repeated ideas, '
      'unfinished thoughts, questions answered much later, and clips that '
      'depend on visuals not represented in this transcript.\n'
      '- Keep it between ${rules.minSeconds.round()} and '
      '${rules.maxSeconds.round()} seconds; aim for 20–60 seconds and include '
      'enough surrounding context for the payoff.\n'
      '- Use only the exact timestamp boundaries in the transcript. Do not '
      'invent times or cut through a spoken segment. Candidates must not '
      'overlap.\n'
      '- "title" is a specific, filename-safe label (not "Interesting clip"). '
      '"hook" must quote or faithfully paraphrase the first spoken sentence. '
      '"reason" names the payoff and why it stands alone. "confidence" is '
      'your 0–1 editorial confidence, not a probability.\n\n'
      'Output only the requested JSON. Never pad the list with mediocre clips.';

  String _minutes(double seconds) {
    final m = (seconds / 60).round();
    return m <= 1 ? 'about a minute' : 'about $m minutes';
  }

  /// Clamps, filters, de-overlaps and caps (SHT-6).
  ///
  /// Pure and separately testable, because this is the part that has to hold
  /// when a model hallucinates a timestamp past the end of the media.
  List<ShortCandidate> sanitizeCandidates(
    List<ShortCandidate> candidates, {
    required double mediaDurationSec,
    Transcript? transcript,
  }) {
    final limit = mediaDurationSec > 0 ? mediaDurationSec : double.infinity;

    final cleaned = <ShortCandidate>[];
    for (final c in candidates) {
      var start = c.startSec;
      var end = c.endSec;

      // A model that returns the range backwards means the range, not nothing.
      if (end < start) {
        final swap = start;
        start = end;
        end = swap;
      }

      start = start.clamp(0.0, limit.isFinite ? limit : start);
      end = end.clamp(0.0, limit.isFinite ? limit : end);

      if (end - start > rules.maxSeconds) end = start + rules.maxSeconds;
      if (end - start < rules.minSeconds) continue;

      // Nudge onto speech boundaries when we have them, so the cut lands
      // between words (SHT-5).
      if (transcript != null && transcript.segments.isNotEmpty) {
        final snappedStart = transcript.snapToBoundary(start);
        final snappedEnd = transcript.snapToBoundary(end);
        if (snappedEnd - snappedStart >= rules.minSeconds &&
            snappedStart >= 0 &&
            snappedEnd <= limit) {
          start = snappedStart;
          end = snappedEnd;
        }
      }

      cleaned.add(c.copyWith(startSec: start, endSec: end));
    }

    // Overlaps resolve in favour of the higher-confidence candidate, so the
    // list is what the model ranked rather than whatever happened to be first.
    cleaned.sort((a, b) => b.confidence.compareTo(a.confidence));
    final kept = <ShortCandidate>[];
    for (final c in cleaned) {
      final clashes = kept.any(
        (k) => c.startSec < k.endSec && k.startSec < c.endSec,
      );
      if (clashes) continue;
      kept.add(c);
      if (kept.length >= rules.maxCandidates) break;
    }

    kept.sort((a, b) => a.startSec.compareTo(b.startSec));
    return kept;
  }

  /// Creates the 9:16 project for an accepted candidate (SHT-12 … SHT-16).
  ///
  /// Returns the file it wrote.
  Future<File> createProject(
    ShortCandidate candidate, {
    required ProjectDoc source,
    required MediaAsset asset,
    required String sourceProjectPath,
  }) async {
    final doc = ProjectDoc.empty(
      _projectName(candidate, source),
      width: 1080,
      height: 1920,
      fps: source.settings.fpsValue,
    );
    doc.settings.audioSampleRate = source.settings.audioSampleRate;

    // The same asset id and hash, so the new project reuses the cached
    // thumbnails, peaks, proxy and transcript straight away rather than
    // re-probing a file it already knows (SHT-13).
    doc.media.add(_copyAsset(asset));

    final videoTrack = doc.tracks.firstWhere((t) => t.kind == 'video');
    final audioTrack = doc.tracks.firstWhere((t) => t.kind == 'audio');

    final start = Rt.zero();
    final duration = Rt.fromSeconds(candidate.durationSec);
    final sourceIn = Rt.fromSeconds(candidate.startSec);
    final linkGroup = generateId();

    doc.clips.add(
      Clip(
        id: generateId(),
        trackId: videoTrack.id,
        mediaId: asset.id,
        label: asset.name,
        start: start,
        duration: duration,
        sourceIn: sourceIn,
        linkedGroup: linkGroup,
        // Crop-to-fill: the compositor already implements this as max(sx, sy),
        // so a 16:9 source fills the 9:16 canvas centred with no new render
        // code, and the canvas gizmo can reposition it immediately (SHT-14).
        transform: ClipTransform(framing: 'fill'),
      ),
    );

    if (asset.hasAudio) {
      doc.clips.add(
        Clip(
          id: generateId(),
          trackId: audioTrack.id,
          mediaId: asset.id,
          label: asset.name,
          start: start,
          duration: duration,
          sourceIn: sourceIn,
          linkedGroup: linkGroup,
        ),
      );
    }

    final file = await _uniqueFile(sourceProjectPath, doc.name);
    await ProjectRepository.writeAtomic(file, doc.encode());
    return file;
  }

  MediaAsset _copyAsset(MediaAsset asset) => MediaAsset(
    id: asset.id,
    name: asset.name,
    path: asset.path,
    type: asset.type,
    duration: asset.duration,
    hasAudio: asset.hasAudio,
    hash: asset.hash,
    width: asset.width,
    height: asset.height,
    fps: asset.fps,
    rotation: asset.rotation,
    vfr: asset.vfr,
    codec: asset.codec,
    hdr: asset.hdr,
    bitrate: asset.bitrate,
    proxyPath: asset.proxyPath,
    sourceKind: asset.sourceKind,
    remoteEtag: asset.remoteEtag,
    remoteLastModified: asset.remoteLastModified,
    remoteContentLength: asset.remoteContentLength,
    extra: Map<String, dynamic>.of(asset.extra),
  );

  /// `<project> — <title>`, falling back to the in-point's timecode when the
  /// model gave us nothing usable (SHT-16).
  String _projectName(ShortCandidate candidate, ProjectDoc source) {
    final safe = _safeTitle(candidate.title);
    final label = safe.isEmpty ? _timecode(candidate.startSec) : safe;
    return '${source.name} — $label';
  }

  static String _safeTitle(String title) {
    final cleaned = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.length <= 60 ? cleaned : cleaned.substring(0, 60).trim();
  }

  static String _timecode(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '${h}h$mm.$ss' : '$mm.$ss';
  }

  /// Writes beside the source project, de-duplicated with a numeric suffix the
  /// way an export output path is (SHT-15, EXP-13).
  Future<File> _uniqueFile(String sourceProjectPath, String name) async {
    final dir = File(sourceProjectPath).parent;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final sep = Platform.pathSeparator;
    var candidate = File('${dir.path}$sep$name.crazycut');
    var counter = 1;
    while (candidate.existsSync()) {
      candidate = File('${dir.path}$sep$name (${counter++}).crazycut');
      if (counter > 999) break;
    }
    return candidate;
  }
}

/// Rounds a time to the nearest frame at [fps], so a nudged in/out point stays
/// on a frame boundary rather than landing between two.
double snapToFrame(double seconds, double fps) {
  if (fps <= 0) return seconds;
  return (seconds * fps).roundToDouble() / fps;
}

/// Clamped nudge for the review panel (SHT-9).
ShortCandidate nudgeCandidate(
  ShortCandidate candidate, {
  double startDelta = 0,
  double endDelta = 0,
  required double mediaDurationSec,
  required ShortsRules rules,
}) {
  var start = math.max(0.0, candidate.startSec + startDelta);
  var end = math.min(mediaDurationSec, candidate.endSec + endDelta);
  if (end - start < rules.minSeconds) {
    // Refuse the nudge rather than silently producing something unusable.
    return candidate;
  }
  if (end - start > rules.maxSeconds) {
    if (endDelta != 0) {
      end = start + rules.maxSeconds;
    } else {
      start = end - rules.maxSeconds;
    }
  }
  return candidate.copyWith(startSec: start, endSec: end);
}
