part of 'project.dart';

class Clip {
  Clip({
    required this.id,
    required this.trackId,
    required this.mediaId,
    required this.label,
    required this.start,
    required this.duration,
    required this.sourceIn,
    this.speed = '1/1',
    this.reverse = false,
    this.volume = 1.0,
    this.pan = 0.0,
    this.mute = false,
    Fade? fadeIn,
    Fade? fadeOut,
    this.linkedGroup,
    List<dynamic>? effects,
    this.blend = 'normal',
    this.transform,
    this.text,
    Map<String, dynamic>? extra,
  }) : fadeIn = fadeIn ?? Fade(),
       fadeOut = fadeOut ?? Fade(),
       effects = effects ?? [],
       extra = extra ?? {};

  /// Blend mode of this clip over the composite below it (engine contract):
  /// normal|multiply|screen|overlay|add|softLight.
  String blend;

  /// Built-in transform (FX-9); null until a transform edit exists.
  ClipTransform? transform;

  /// Text payload; non-null only on text clips (whose [mediaId] is '').
  TextContent? text;

  factory Clip.fromJson(Map<String, dynamic> j) => Clip(
    id: j['id'] as String,
    trackId: j['trackId'] as String,
    mediaId: j['mediaId'] as String,
    label: (j['label'] as String?) ?? '',
    start: Rt.parse(j['start'] as String),
    duration: Rt.parse(j['duration'] as String),
    sourceIn:
        j['sourceIn'] == null ? Rt.zero() : Rt.parse(j['sourceIn'] as String),
    speed: switch (j['speed']) {
      final String value => value,
      final Map<String, dynamic> value =>
        '${(value['num'] as num?)?.toInt() ?? 1}/${(value['den'] as num?)?.toInt() ?? 1}',
      _ => '1/1',
    },
    reverse: (j['reverse'] as bool?) ?? false,
    volume: (j['volume'] as num?)?.toDouble() ?? 1.0,
    pan: (j['pan'] as num?)?.toDouble() ?? 0.0,
    mute: (j['mute'] as bool?) ?? false,
    fadeIn: Fade.fromJson(j['fadeIn'] as Map<String, dynamic>?),
    fadeOut: Fade.fromJson(j['fadeOut'] as Map<String, dynamic>?),
    linkedGroup: j['linkedGroup'] as String?,
    effects: (j['effects'] as List<dynamic>?)?.toList(),
    blend: (j['blend'] as String?) ?? 'normal',
    transform:
        j['transform'] == null
            ? null
            : ClipTransform.fromJson(j['transform'] as Map<String, dynamic>),
    text:
        j['text'] == null
            ? null
            : TextContent.fromJson(j['text'] as Map<String, dynamic>),
    extra: _clipExtra(j),
  );

  final String id;
  String trackId;
  final String mediaId;
  String label;
  Rt start;
  Rt duration;
  Rt sourceIn;
  String speed;
  bool reverse;
  double volume;
  double pan;
  bool mute;
  Fade fadeIn;
  Fade fadeOut;

  /// Shared by clips cut from the same source so they move together (TIM-3).
  String? linkedGroup;
  final List<dynamic> effects;
  final Map<String, dynamic> extra;

  Rt get end => start.plus(duration);

  /// Lazily-defaulted transform for read paths; persistence is decided by the
  /// ops layer, so mutating the returned default does not mark the clip.
  ClipTransform get transformOrDefault => transform ?? ClipTransform();

  double get speedValue {
    final parts = speed.split('/');
    final n = int.tryParse(parts.first) ?? 1;
    final d = parts.length > 1 ? (int.tryParse(parts.last) ?? 1) : 1;
    return d == 0 ? 1 : n / d;
  }

  /// How much source the clip consumes, i.e. duration × speed.
  Rt get sourceSpan => Rt.fromMicros((duration.micros * speedValue).round());

  Clip copy() => Clip.fromJson(toJson());

  /// Same content, new identity — for copy/paste and duplicate (§3).
  Clip cloneWithNewId({String? trackId, Rt? start, String? linkedGroup}) {
    final json = toJson();
    json['id'] = generateId();
    if (trackId != null) json['trackId'] = trackId;
    if (start != null) json['start'] = start.toString();
    json['linkedGroup'] = linkedGroup;
    return Clip.fromJson(json);
  }

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'trackId': trackId,
    'mediaId': mediaId,
    'label': label,
    'start': start.toString(),
    'duration': duration.toString(),
    'sourceIn': sourceIn.toString(),
    'speed': {
      'num': int.tryParse(speed.split('/').first) ?? 1,
      'den': int.tryParse(speed.split('/').last) ?? 1,
    },
    'reverse': reverse,
    'volume': volume,
    'pan': pan,
    'mute': mute,
    'fadeIn': fadeIn.toJson(),
    'fadeOut': fadeOut.toJson(),
    if (linkedGroup != null) 'linkedGroup': linkedGroup,
    'effects': effects,
    if (blend != 'normal') 'blend': blend,
    if (transform != null) 'transform': transform!.toJson(),
    if (text != null) 'text': text!.toJson(),
  };
}
