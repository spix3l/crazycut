import 'package:crazycut_app/models/rational.dart';

Map<String, dynamic> _unknown(Map<String, dynamic> json, Set<String> known) => {
  for (final entry in json.entries)
    if (!known.contains(entry.key)) entry.key: entry.value,
};

dynamic _copyJsonValue(dynamic value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _copyJsonValue(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _copyJsonValue(item)];
  return value;
}

Map<String, dynamic> _copyJson(Map<String, dynamic> value) =>
    _copyJsonValue(value) as Map<String, dynamic>;

/// Visual defaults shared by every cue on a caption track.
///
/// The renderer may add more properties later; unknown values survive a
/// load/save round trip so a newer project is not damaged by an older build.
class CaptionStyle {
  CaptionStyle({
    this.preset = 'default',
    this.fontFamily = '',
    this.fontSize = 48.0,
    this.textColor = '#FFFFFFFF',
    this.backgroundColor = '#00000000',
    this.alignment = 'center',
    this.positionX = 0.5,
    this.positionY = 0.88,
    this.maxWidth = 0.9,
    this.highlightWords = false,
    this.highlightColor = '#F5C451FF',
    Map<String, dynamic>? extra,
  }) : extra = extra ?? {};

  factory CaptionStyle.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const <String, dynamic>{};
    return CaptionStyle(
      preset: (j['preset'] as String?) ?? 'default',
      fontFamily: (j['fontFamily'] as String?) ?? '',
      fontSize: (j['fontSize'] as num?)?.toDouble() ?? 48.0,
      textColor: (j['textColor'] as String?) ?? '#FFFFFFFF',
      backgroundColor: (j['backgroundColor'] as String?) ?? '#00000000',
      alignment: (j['alignment'] as String?) ?? 'center',
      positionX: (j['positionX'] as num?)?.toDouble() ?? 0.5,
      positionY: (j['positionY'] as num?)?.toDouble() ?? 0.88,
      maxWidth: (j['maxWidth'] as num?)?.toDouble() ?? 0.9,
      highlightWords: (j['highlightWords'] as bool?) ?? false,
      highlightColor: (j['highlightColor'] as String?) ?? '#F5C451FF',
      extra: _unknown(j, {
        'preset',
        'fontFamily',
        'fontSize',
        'textColor',
        'backgroundColor',
        'alignment',
        'positionX',
        'positionY',
        'maxWidth',
        'highlightWords',
        'highlightColor',
      }),
    );
  }

  String preset;
  String fontFamily;
  double fontSize;
  String textColor;
  String backgroundColor;
  String alignment;
  double positionX;
  double positionY;
  double maxWidth;
  bool highlightWords;
  String highlightColor;
  final Map<String, dynamic> extra;

  CaptionStyle copy() => CaptionStyle.fromJson(_copyJson(toJson()));

  Map<String, dynamic> toJson() => {
    ...extra,
    'preset': preset,
    'fontFamily': fontFamily,
    'fontSize': fontSize,
    'textColor': textColor,
    'backgroundColor': backgroundColor,
    'alignment': alignment,
    'positionX': positionX,
    'positionY': positionY,
    'maxWidth': maxWidth,
    'highlightWords': highlightWords,
    'highlightColor': highlightColor,
  };
}

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

class CaptionTrack {
  CaptionTrack({
    required this.id,
    required this.name,
    required this.language,
    CaptionStyle? style,
    List<CaptionItem>? items,
    Map<String, dynamic>? extra,
  }) : style = style ?? CaptionStyle(),
       items = items ?? [],
       extra = extra ?? {};

  factory CaptionTrack.fromJson(
    Map<String, dynamic> j, {
    void Function(String what, Object error)? onError,
  }) {
    final items = <CaptionItem>[];
    for (final item in (j['items'] as List<dynamic>? ?? const [])) {
      try {
        items.add(
          CaptionItem.fromJson(
            item as Map<String, dynamic>,
            onError: (what, error) => onError?.call('item $what', error),
          ),
        );
      } catch (error) {
        onError?.call('item', error);
      }
    }
    return CaptionTrack(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? 'Captions',
      language: (j['language'] as String?) ?? 'und',
      style: CaptionStyle.fromJson(j['style'] as Map<String, dynamic>?),
      items: items,
      extra: _unknown(j, {'id', 'name', 'language', 'style', 'items'}),
    );
  }

  final String id;
  String name;
  String language;
  CaptionStyle style;
  final List<CaptionItem> items;
  final Map<String, dynamic> extra;

  CaptionTrack copy() => CaptionTrack.fromJson(_copyJson(toJson()));

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'name': name,
    'language': language,
    'style': style.toJson(),
    'items': [for (final item in items) item.toJson()],
  };
}
