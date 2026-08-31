part of 'template.dart';

/// How a template joins the clip before or after it (TPL-8). A spec rather
/// than an entity: insertion feeds it to the normal `addTransition` path so
/// handle rules stay identical to a hand-made transition.
class TemplateEdge {
  TemplateEdge({
    this.enabled = false,
    this.type = 'crossDissolve',
    Rt? duration,
    String? easing,
  }) : duration = duration ?? Rt.parse('1/2'),
       easing = easing ?? Transition.defaultEasingFor(type);

  factory TemplateEdge.fromJson(Map<String, dynamic>? j) => TemplateEdge(
    enabled: (j?['enabled'] as bool?) ?? false,
    type: (j?['type'] as String?) ?? 'crossDissolve',
    duration:
        j?['duration'] == null ? null : Rt.parse(j!['duration'] as String),
    easing: j?['easing'] as String?,
  );

  bool enabled;
  String type;
  Rt duration;
  String easing;

  TemplateEdge copy() => TemplateEdge.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'type': type,
    'duration': duration.toString(),
    'easing': easing,
  };
}
