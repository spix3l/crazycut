part of 'template.dart';

/// What an insert is allowed to change about a template (TPL-5).
enum SlotKind {
  /// Rewrites a text clip's content.
  text,

  /// Repoints a clip at another asset in the project.
  media,

  /// Scales the whole chunk proportionally.
  duration;

  static SlotKind parse(String? name) =>
      SlotKind.values.firstWhereOrNull((k) => k.name == name) ?? SlotKind.text;
}
