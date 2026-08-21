import 'package:crazycut_app/models/rational.dart';

/// Typed transition entity (`02-data-model.md` §5, `03-features/transitions.md`).
class Transition {
  Transition({
    required this.id,
    required this.aClipId,
    required this.bClipId,
    this.type = 'crossDissolve',
    Rt? duration,
    this.alignment = 'center',
    String? easing,
    Rt? aExtend,
    Rt? bExtend,
    Map<String, dynamic>? params,
  })  : duration = duration ?? Rt.parse('1/2'),
        aExtend = aExtend ?? Rt.zero(),
        bExtend = bExtend ?? Rt.zero(),
        easing = easing ?? defaultEasingFor(type),
        params = params ?? {};

  factory Transition.fromJson(Map<String, dynamic> j) => Transition(
        id: j['id'] as String,
        aClipId: j['aClipId'] as String? ?? '',
        bClipId: j['bClipId'] as String? ?? '',
        type: j['type'] as String? ?? 'crossDissolve',
        duration: j['duration'] == null ? null : Rt.parse(j['duration'] as String),
        alignment: switch (j['alignment']) {
          'start' => 'start',
          'end' => 'end',
          _ => 'center',
        },
        easing: j['easing'] as String?,
        aExtend: j['aExtend'] == null ? Rt.zero() : Rt.parse(j['aExtend'] as String),
        bExtend: j['bExtend'] == null ? Rt.zero() : Rt.parse(j['bExtend'] as String),
        params: (j['params'] as Map<String, dynamic>?) ?? {},
      );

  final String id;
  final String aClipId;
  final String bClipId;
  String type;
  Rt duration;
  String alignment;

  /// Catalog default applied when the JSON omits easing.
  String easing;

  /// Sequence-time handle seconds consumed each side; restoring butt-joint
  /// geometry on removal relies on these (TRA-4).
  Rt aExtend;
  Rt bExtend;
  Map<String, dynamic> params;

  /// Easing defaults per catalog: slides ease out, pushes stay linear, the
  /// rest ease in-out.
  static String defaultEasingFor(String type) => switch (type) {
        'slideLeft' || 'slideRight' || 'slideUp' || 'slideDown' => 'easeOut',
        'pushLeft' || 'pushRight' || 'pushUp' || 'pushDown' => 'linear',
        _ => 'easeInOut',
      };

  /// Same transition, optionally re-identified and/or re-pointed — for
  /// project duplicate, which remaps clip ids through its fresh-id map.
  Transition copy({
    String? id,
    String? aClipId,
    String? bClipId,
  }) =>
      Transition(
        id: id ?? this.id,
        aClipId: aClipId ?? this.aClipId,
        bClipId: bClipId ?? this.bClipId,
        type: type,
        duration: duration,
        alignment: alignment,
        easing: easing,
        aExtend: aExtend,
        bExtend: bExtend,
        params: {...params},
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'aClipId': aClipId,
        'bClipId': bClipId,
        'type': type,
        'duration': duration.toString(),
        'alignment': alignment,
        'easing': easing,
        'aExtend': aExtend.toString(),
        'bExtend': bExtend.toString(),
        'params': params,
      };
}
