part of 'project.dart';

class Track {
  Track({
    required this.id,
    required this.kind,
    required this.name,
    required this.index,
    this.mute = false,
    this.solo = false,
    this.lock = false,
    this.hidden = false,
    this.height = 72,
    this.gain = 1.0,
    this.pan = 0.0,
    Map<String, dynamic>? extra,
  }) : extra = extra ?? {};

  final String id;
  final String kind;
  String name;
  int index;
  bool mute;
  bool solo;
  bool lock;
  bool hidden;
  int height;

  /// Mixer strip state (AUD-10): linear fader and balance. Video tracks carry
  /// them too so a linked A/V clip's audio follows its own track.
  double gain;
  double pan;
  final Map<String, dynamic> extra;

  bool get isVideo => kind == 'video';

  Track copy() => Track.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'kind': kind,
    'name': name,
    'index': index,
    'mute': mute,
    'solo': solo,
    'lock': lock,
    'hidden': hidden,
    'height': height,
    'gain': gain,
    'pan': pan,
  };

  static Track fromJson(Map<String, dynamic> j) => Track(
    id: j['id'] as String,
    kind: j['kind'] as String,
    name: j['name'] as String,
    index: (j['index'] as num).toInt(),
    mute: (j['mute'] as bool?) ?? false,
    solo: (j['solo'] as bool?) ?? false,
    lock: (j['lock'] as bool?) ?? false,
    hidden: (j['hidden'] as bool?) ?? false,
    height: (j['height'] as num?)?.toInt() ?? 72,
    gain: (j['gain'] as num?)?.toDouble() ?? 1.0,
    pan: (j['pan'] as num?)?.toDouble() ?? 0.0,
    extra: _unknown(j, {
      'id',
      'kind',
      'name',
      'index',
      'mute',
      'solo',
      'lock',
      'hidden',
      'height',
      'gain',
      'pan',
    }),
  );
}
