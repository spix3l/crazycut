part of 'caption.dart';

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
