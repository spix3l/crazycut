part of 'area_track.dart';

/// A solved motion path.
class Tracker {
  Tracker({
    required this.id,
    required this.mediaId,
    required this.sourceClipId,
    required this.startTime,
    required this.endTime,
    required this.searchQuad,
    required this.fps,
    required this.path,
    required this.confidence,
    this.algorithm = 'lk-homography',
    this.algorithmVersion = 1,
    this.analysisWidth = 720,
    Map<String, dynamic>? extra,
  }) : extra = extra ?? <String, dynamic>{};

  /// Returns null for anything the engine loader would quarantine, so the two
  /// sides agree on what a usable tracker is (**TRK-16**).
  static Tracker? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final mediaId = j['mediaId'];
    final sourceClipId = j['sourceClipId'];
    if (id is! String || id.isEmpty) return null;
    if (mediaId is! String || mediaId.isEmpty) return null;
    if (sourceClipId is! String || sourceClipId.isEmpty) return null;

    final search = _quadOrNull(j['searchQuad']);
    if (search == null) return null;

    final rawPath = j['path'];
    if (rawPath is! List ||
        rawPath.isEmpty ||
        rawPath.length % 8 != 0 ||
        rawPath.any((v) => v is! num || !v.toDouble().isFinite)) {
      return null;
    }
    final path = [for (final v in rawPath) (v as num).toDouble()];

    final rawConfidence = j['confidence'];
    if (rawConfidence is! List ||
        rawConfidence.length != path.length ~/ 8 ||
        rawConfidence.any((v) => v is! num)) {
      return null;
    }

    final fps = _rtOrNull(j['fps']);
    final startTime = _rtOrNull(j['startTime']) ?? Rt.zero();
    final endTime = _rtOrNull(j['endTime']);
    if (fps == null || fps.num <= 0) return null;
    if (endTime == null || endTime <= startTime) return null;

    return Tracker(
      id: id,
      mediaId: mediaId,
      sourceClipId: sourceClipId,
      startTime: startTime,
      endTime: endTime,
      searchQuad: search,
      fps: fps,
      path: path,
      confidence: [for (final v in rawConfidence) (v as num).toDouble()],
      algorithm: (j['algorithm'] as String?) ?? 'lk-homography',
      algorithmVersion: (j['algorithmVersion'] as num?)?.toInt() ?? 1,
      analysisWidth: (j['analysisWidth'] as num?)?.toInt() ?? 720,
      extra: {
        for (final e in j.entries)
          if (!_knownKeys.contains(e.key)) e.key: e.value,
      },
    );
  }

  static const Set<String> _knownKeys = {
    'id',
    'mediaId',
    'sourceClipId',
    'startTime',
    'endTime',
    'searchQuad',
    'algorithm',
    'algorithmVersion',
    'analysisWidth',
    'fps',
    'path',
    'confidence',
  };

  final String id;
  final String mediaId;
  final String sourceClipId;
  final Rt startTime;
  final Rt endTime;

  /// The region the user drew, in source px.
  final Quad searchQuad;

  /// Sample rate of [path] — samples are addressed by index from [startTime],
  /// never searched.
  final Rt fps;

  /// Packed solved quads: 8 numbers per sample, source px, TL/TR/BR/BL
  /// (**TRK-14**).
  final List<double> path;

  /// One 0..1 per sample.
  final List<double> confidence;

  final String algorithm;
  final int algorithmVersion;
  final int analysisWidth;

  /// Forward-safe passthrough of fields this build does not know (§9).
  final Map<String, dynamic> extra;

  int get sampleCount => path.length ~/ 8;

  /// Sample index for a clip-local time, clamped to the solved range.
  int sampleIndexAt(Rt local) {
    if (sampleCount <= 1) return 0;
    final offset = (local - startTime).seconds * fps.seconds;
    if (!offset.isFinite) return 0;
    return offset.floor().clamp(0, sampleCount - 1);
  }

  Quad sample(int index) {
    final i = index.clamp(0, sampleCount - 1) * 8;
    return path.sublist(i, i + 8);
  }

  double confidenceAt(Rt local) =>
      confidence.isEmpty ? 0.0 : confidence[sampleIndexAt(local)];

  /// The tracked quad at a clip-local time, in source px.
  ///
  /// Samples are interpolated linearly between neighbours so a simplified path
  /// (**TRK-14**) still moves smoothly rather than stepping between stored
  /// samples. Outside the solved range the path holds its end pose, which is
  /// what the engine's clamped keyframe evaluation does too.
  Quad quadAt(Rt local) {
    if (sampleCount == 0) return searchQuad;
    if (sampleCount == 1) return sample(0);
    final offset = (local - startTime).seconds * fps.seconds;
    if (!offset.isFinite || offset <= 0) return sample(0);
    if (offset >= sampleCount - 1) return sample(sampleCount - 1);
    final i = offset.floor();
    final t = offset - i;
    final a = sample(i);
    final b = sample(i + 1);
    return [for (var k = 0; k < 8; k += 1) a[k] + (b[k] - a[k]) * t];
  }

  /// Clip-local time ranges where the solve fell below [threshold], for the
  /// timeline's warning stripe (**TRK-8**, UX notes).
  List<({Rt start, Rt end})> lowConfidenceSpans({double threshold = 0.4}) {
    final spans = <({Rt start, Rt end})>[];
    final step = fps.seconds <= 0 ? 0.0 : 1.0 / fps.seconds;
    int? runStart;
    for (var i = 0; i <= confidence.length; i += 1) {
      final low = i < confidence.length && confidence[i] < threshold;
      if (low && runStart == null) {
        runStart = i;
      } else if (!low && runStart != null) {
        spans.add((
          start: startTime + Rt.fromSeconds(runStart * step),
          end: startTime + Rt.fromSeconds(i * step),
        ));
        runStart = null;
      }
    }
    return spans;
  }

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'mediaId': mediaId,
    'sourceClipId': sourceClipId,
    'startTime': startTime.toString(),
    'endTime': endTime.toString(),
    'searchQuad': searchQuad,
    'algorithm': algorithm,
    'algorithmVersion': algorithmVersion,
    'analysisWidth': analysisWidth,
    'fps': fps.toString(),
    'path': path,
    'confidence': confidence,
  };

  Tracker copyWith({
    Rt? startTime,
    Rt? endTime,
    Quad? searchQuad,
    List<double>? path,
    List<double>? confidence,
  }) => Tracker(
    id: id,
    mediaId: mediaId,
    sourceClipId: sourceClipId,
    startTime: startTime ?? this.startTime,
    endTime: endTime ?? this.endTime,
    searchQuad: searchQuad ?? this.searchQuad,
    fps: fps,
    path: path ?? this.path,
    confidence: confidence ?? this.confidence,
    algorithm: algorithm,
    algorithmVersion: algorithmVersion,
    analysisWidth: analysisWidth,
    extra: extra,
  );
}

Quad? _quadOrNull(dynamic raw) {
  if (raw is! List || raw.length != 8) return null;
  if (raw.any((v) => v is! num || !v.toDouble().isFinite)) return null;
  return [for (final v in raw) (v as num).toDouble()];
}

Quad _quad(dynamic raw) =>
    _quadOrNull(raw) ?? const [0, 0, 0, 0, 0, 0, 0, 0];

Rt? _rtOrNull(dynamic raw) {
  if (raw is String) return Rt.parse(raw);
  if (raw is num) return Rt.fromSeconds(raw.toDouble());
  if (raw is Map && raw['n'] is num && raw['d'] is num) {
    final d = (raw['d'] as num).toInt();
    if (d <= 0) return null;
    return Rt((raw['n'] as num).toInt(), d);
  }
  return null;
}
