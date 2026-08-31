part of 'template.dart';

/// One editable part of a template. [clipId] is template-local and empty for
/// [SlotKind.duration], which acts on the template as a whole.
class TemplateSlot {
  TemplateSlot({
    required this.id,
    required this.kind,
    required this.name,
    this.clipId = '',
    this.defaultValue = '',
    this.hint = '',
  });

  factory TemplateSlot.fromJson(Map<String, dynamic> j) => TemplateSlot(
    id: j['id'] as String,
    kind: SlotKind.parse(j['kind'] as String?),
    name: (j['name'] as String?) ?? '',
    clipId: (j['clipId'] as String?) ?? '',
    defaultValue: (j['default'] as String?) ?? '',
    hint: (j['hint'] as String?) ?? '',
  );

  final String id;
  final SlotKind kind;
  String name;
  final String clipId;

  /// Pre-filled in the insert dialog: the authored text, the authored asset
  /// name, or the authored duration in seconds.
  String defaultValue;
  String hint;

  TemplateSlot copy() => TemplateSlot.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    if (clipId.isNotEmpty) 'clipId': clipId,
    'default': defaultValue,
    if (hint.isNotEmpty) 'hint': hint,
  };
}
