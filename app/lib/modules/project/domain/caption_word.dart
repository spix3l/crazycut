part of 'caption.dart';

/// One recognized word. Times are absolute sequence times, not cue-relative.
class CaptionWord {
  CaptionWord({
    this.id,
    required this.start,
    required this.end,
    required this.text,
    this.confidence,
    Map<String, dynamic>? extra,
  }) : extra = extra ?? {};

  factory CaptionWord.fromJson(Map<String, dynamic> j) => CaptionWord(
    id: j['id'] as String?,
    start: Rt.parse(j['start'] as String),
    end: Rt.parse(j['end'] as String),
    text: (j['text'] as String?) ?? '',
    confidence: (j['confidence'] as num?)?.toDouble(),
    extra: _unknown(j, {'id', 'start', 'end', 'text', 'confidence'}),
  );

  final String? id;
  Rt start;
  Rt end;
  String text;
  double? confidence;
  final Map<String, dynamic> extra;

  CaptionWord copy() => CaptionWord.fromJson(_copyJson(toJson()));

  Map<String, dynamic> toJson() => {
    ...extra,
    if (id != null) 'id': id,
    'start': start.toString(),
    'end': end.toString(),
    'text': text,
    if (confidence != null) 'confidence': confidence,
  };
}
