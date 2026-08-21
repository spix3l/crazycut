/// Text clip content (TXT-2/3).
///
/// [animation] is provenance only (which preset produced this clip); presets
/// bake their keyframes elsewhere, so nothing here evaluates them.
class TextContent {
  TextContent({
    this.content = '',
    this.fontFamily = 'default',
    this.fontSize = 64,
    this.fontWeight = 'w600',
    this.color = '#FFFFFF',
    this.letterSpacing = 0,
    this.lineHeight = 1.2,
    this.align = 'center',
    this.strokeWidth = 0,
    this.strokeColor = '#000000',
    this.shadowBlur = 0,
    this.shadowOffsetX = 0,
    this.shadowOffsetY = 0,
    this.shadowColor = '#000000',
    this.shadowOpacity = 0,
    this.backgroundColor = '#00000000',
    this.backgroundPadding = 0,
    this.backgroundRadius = 0,
    this.animation = '',
  });

  factory TextContent.fromJson(Map<String, dynamic>? j) {
    final stroke = (j?['stroke'] as Map<String, dynamic>?) ?? const {};
    final shadow = (j?['shadow'] as Map<String, dynamic>?) ?? const {};
    final background = (j?['background'] as Map<String, dynamic>?) ?? const {};
    return TextContent(
      content: (j?['content'] as String?) ?? '',
      fontFamily: (j?['fontFamily'] as String?) ?? 'default',
      fontSize: (j?['fontSize'] as num?)?.toDouble() ?? 64,
      fontWeight: _weight(j?['fontWeight']),
      color: (j?['color'] as String?) ?? '#FFFFFF',
      letterSpacing: (j?['letterSpacing'] as num?)?.toDouble() ?? 0,
      lineHeight: (j?['lineHeight'] as num?)?.toDouble() ?? 1.2,
      align: switch (j?['align']) { 'left' => 'left', 'right' => 'right', _ => 'center' },
      strokeWidth: (stroke['width'] as num?)?.toDouble() ??
          (j?['strokeWidth'] as num?)?.toDouble() ?? 0,
      strokeColor: (stroke['color'] as String?) ??
          (j?['strokeColor'] as String?) ?? '#000000',
      shadowBlur: (shadow['blur'] as num?)?.toDouble() ??
          (j?['shadowBlur'] as num?)?.toDouble() ?? 0,
      shadowOffsetX: (shadow['offsetX'] as num?)?.toDouble() ??
          (j?['shadowOffsetX'] as num?)?.toDouble() ?? 0,
      shadowOffsetY: (shadow['offsetY'] as num?)?.toDouble() ??
          (j?['shadowOffsetY'] as num?)?.toDouble() ?? 0,
      shadowColor: (shadow['color'] as String?) ??
          (j?['shadowColor'] as String?) ?? '#000000',
      shadowOpacity: (shadow['opacity'] as num?)?.toDouble() ??
          (j?['shadowOpacity'] as num?)?.toDouble() ?? 0,
      backgroundColor: (background['color'] as String?) ??
          (j?['backgroundColor'] as String?) ?? '#00000000',
      backgroundPadding: (background['padding'] as num?)?.toDouble() ??
          (j?['backgroundPadding'] as num?)?.toDouble() ?? 0,
      backgroundRadius: (background['radius'] as num?)?.toDouble() ??
          (j?['backgroundRadius'] as num?)?.toDouble() ?? 0,
      animation: (j?['animation'] as String?) ?? '',
    );
  }

  static String _weight(dynamic raw) =>
      raw is String && raw.length == 4 && raw.startsWith('w')
          ? switch (raw) {
              'w400' || 'w500' || 'w600' || 'w700' || 'w800' => raw,
              _ => 'w600',
            }
          : 'w600';

  String content;
  String fontFamily;
  double fontSize;
  String fontWeight;
  String color;
  double letterSpacing;
  double lineHeight;
  String align;
  double strokeWidth;
  String strokeColor;
  double shadowBlur;
  double shadowOffsetX;
  double shadowOffsetY;
  String shadowColor;
  double shadowOpacity;
  String backgroundColor;
  double backgroundPadding;
  double backgroundRadius;

  /// Preset provenance only — never evaluated by the model.
  String animation;

  TextContent copy() => TextContent.fromJson(toJson());

  /// Nested groups keep the text node compact; flat keys are tolerated on read.
  Map<String, dynamic> toJson() => {
        'content': content,
        'fontFamily': fontFamily,
        'fontSize': fontSize,
        'fontWeight': fontWeight,
        'color': color,
        'letterSpacing': letterSpacing,
        'lineHeight': lineHeight,
        'align': align,
        'stroke': {'width': strokeWidth, 'color': strokeColor},
        'shadow': {
          'blur': shadowBlur,
          'offsetX': shadowOffsetX,
          'offsetY': shadowOffsetY,
          'color': shadowColor,
          'opacity': shadowOpacity,
        },
        'background': {
          'color': backgroundColor,
          'padding': backgroundPadding,
          'radius': backgroundRadius,
        },
        'animation': animation,
      };
}

/// Blend modes for clips (engine compositor contract).
const List<String> kBlendModes = [
  'normal',
  'multiply',
  'screen',
  'overlay',
  'add',
  'softLight',
];
