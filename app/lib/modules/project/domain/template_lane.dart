part of 'template.dart';

/// A lane of the template, addressed by offset instead of by track id so the
/// chunk lands correctly in a project with a different track layout (TPL-11).
class TemplateLane {
  TemplateLane({
    required this.key,
    required this.kind,
    required this.offset,
    this.name = '',
  });

  factory TemplateLane.fromJson(Map<String, dynamic> j) => TemplateLane(
    key: j['key'] as String,
    kind: (j['kind'] as String?) ?? 'video',
    offset: ((j['offset'] as num?) ?? 0).toInt(),
    name: (j['name'] as String?) ?? '',
  );

  /// Template-local id, referenced by the captured clips' `trackId`.
  final String key;
  final String kind;

  /// Lanes above the template's base lane of the same kind; 0 is the base.
  final int offset;
  final String name;

  bool get isVideo => kind == 'video';

  Map<String, dynamic> toJson() => {
    'key': key,
    'kind': kind,
    'offset': offset,
    if (name.isNotEmpty) 'name': name,
  };
}
