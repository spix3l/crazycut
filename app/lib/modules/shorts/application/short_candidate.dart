part of 'shorts_service.dart';

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
