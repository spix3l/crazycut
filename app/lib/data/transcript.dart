/// Timed speech for a media asset (AI-22).
///
/// Segment times are seconds in the media's own domain, which is what makes
/// them usable directly as cut points — a shorts candidate that starts on a
/// segment boundary starts between words rather than through one (SHT-5).
library;

import 'dart:convert';

class TranscriptSegment {
  const TranscriptSegment({
    required this.start,
    required this.end,
    required this.text,
  });

  final double start;
  final double end;
  final String text;

  double get duration => end - start;

  static TranscriptSegment? fromJson(Map<String, dynamic> json) {
    final start = (json['start'] as num?)?.toDouble();
    final end = (json['end'] as num?)?.toDouble();
    final text = json['text'] as String?;
    if (start == null || end == null || text == null) return null;
    if (text.trim().isEmpty) return null;
    return TranscriptSegment(start: start, end: end, text: text.trim());
  }

  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'text': text};
}

class Transcript {
  const Transcript({
    required this.language,
    required this.durationSeconds,
    required this.segments,
  });

  final String language;
  final double durationSeconds;
  final List<TranscriptSegment> segments;

  bool get isEmpty => segments.isEmpty;

  String get plainText => segments.map((s) => s.text).join(' ');

  /// The form sent to a model: one line per segment, timestamped, so it can
  /// cite boundaries back at us instead of inventing them.
  String toTimedText() {
    final buffer = StringBuffer();
    for (final s in segments) {
      buffer.writeln(
        '[${_stamp(s.start)} - ${_stamp(s.end)}] ${s.text}',
      );
    }
    return buffer.toString().trimRight();
  }

  static String _stamp(double seconds) {
    final total = seconds.round();
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Nearest segment boundary to [seconds], for snapping a nudged in/out point
  /// back onto speech.
  double snapToBoundary(double seconds, {bool preferStart = true}) {
    if (segments.isEmpty) return seconds;
    var best = seconds;
    var bestDistance = double.infinity;
    for (final s in segments) {
      for (final candidate in [s.start, s.end]) {
        final distance = (candidate - seconds).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          best = candidate;
        }
      }
    }
    return best;
  }

  static Transcript? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final rawSegments = json['segments'];
      if (rawSegments is! List) return null;
      return Transcript(
        language: json['language'] as String? ?? 'unknown',
        durationSeconds: (json['durationSeconds'] as num?)?.toDouble() ?? 0,
        segments: [
          for (final entry in rawSegments)
            if (entry is Map<String, dynamic>)
              ?TranscriptSegment.fromJson(entry),
        ],
      );
    } on Object {
      // A corrupt cache entry is the same as no cache entry.
      return null;
    }
  }

  String encode() => jsonEncode({
    'version': 1,
    'language': language,
    'durationSeconds': durationSeconds,
    'segments': [for (final s in segments) s.toJson()],
  });
}
