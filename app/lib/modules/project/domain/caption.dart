import 'package:crazycut_app/core/math/rational.dart';

part 'caption_item.dart';
part 'caption_style.dart';
part 'caption_track.dart';
part 'caption_word.dart';

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
