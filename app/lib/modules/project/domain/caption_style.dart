part of 'caption.dart';

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
