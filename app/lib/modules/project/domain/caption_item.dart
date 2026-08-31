part of 'caption.dart';

class CaptionItem {
  CaptionItem({
    required this.id,
    required this.start,
    required this.duration,
    required this.text,
    this.speaker,
    List<CaptionWord>? words,
    Map<String, dynamic>? extra,
  }) : words = words ?? [],
       extra = extra ?? {};

  factory CaptionItem.fromJson(
    Map<String, dynamic> j, {
    void Function(String what, Object error)? onError,
  }) {
    final words = <CaptionWord>[];
    for (final word in (j['words'] as List<dynamic>? ?? const [])) {
      try {
        words.add(CaptionWord.fromJson(word as Map<String, dynamic>));
      } catch (error) {
        onError?.call('word', error);
      }
    }
    return CaptionItem(
      id: j['id'] as String,
      start: Rt.parse(j['start'] as String),
      duration: Rt.parse(j['duration'] as String),
      text: (j['text'] as String?) ?? '',
      speaker: j['speaker'] as String?,
      words: words,
      extra: _unknown(j, {
        'id',
        'start',
        'duration',
        'text',
        'speaker',
        'words',
      }),
    );
  }

  final String id;
  Rt start;
  Rt duration;
  String text;
  String? speaker;
  final List<CaptionWord> words;
  final Map<String, dynamic> extra;

  Rt get end => start.plus(duration);

  CaptionItem copy() => CaptionItem.fromJson(_copyJson(toJson()));

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'start': start.toString(),
    'duration': duration.toString(),
    'text': text,
    if (speaker != null) 'speaker': speaker,
    if (words.isNotEmpty) 'words': [for (final word in words) word.toJson()],
  };
}
