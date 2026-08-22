import 'dart:convert';

import 'package:collection/collection.dart';

import 'package:crazycut_app/data/clip_transform.dart';
import 'package:crazycut_app/data/param_value.dart';
import 'package:crazycut_app/data/text_content.dart';
import 'package:crazycut_app/data/transition.dart';
import 'package:crazycut_app/models/rational.dart';

const String kSchemaVersion = 'crazycut/project@1';

/// UUIDv7-shaped id: 48-bit millisecond timestamp then randomness, so ids sort
/// in creation order (`02-data-model.md` §3).
String generateId() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final rand = _random;
  String hex(int value, int digits) => (value & ((1 << (digits * 4)) - 1))
      .toRadixString(16)
      .padLeft(digits, '0');
  final a = hex(now >> 16, 8);
  final b = hex(now, 4);
  final c = '7${hex(rand.nextInt(0x1000), 3)}';
  final d = ((8 + rand.nextInt(4)) << 12) | rand.nextInt(0x1000);
  final e =
      '${hex(rand.nextInt(0xFFFFFFFF), 8)}${hex(rand.nextInt(0xFFFF), 4)}';
  return '$a-$b-$c-${hex(d, 4)}-$e';
}

final _random = _XorShift(DateTime.now().microsecondsSinceEpoch);

/// Tiny deterministic PRNG — `dart:math`'s Random would do, but this keeps the
/// id generator dependency-free and seedable in tests.
class _XorShift {
  _XorShift(int seed) : _state = seed == 0 ? 0x2545F4914F6CDD1D : seed;
  int _state;

  int nextInt(int max) {
    _state ^= (_state << 13) & 0xFFFFFFFFFFFFFFF;
    _state ^= _state >> 7;
    _state ^= (_state << 17) & 0xFFFFFFFFFFFFFFF;
    return (_state.abs()) % (max <= 0 ? 1 : max);
  }
}

/// Fields we do not model yet are carried through load → save untouched
/// (`02-data-model.md` §1 "forward-safe").
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

/// Migrates the pre-v1 visual animation payload to the generic clip payload.
/// The old field was image-specific and called the two edges `in`/`out`; the
/// persisted model now names the same behaviors `entry`/`leave` for every
/// visual clip type.
Map<String, dynamic>? _migrateClipAnimation(dynamic value) {
  if (value is! Map) return null;
  final migrated = _copyJsonValue(value) as Map<String, dynamic>;
  if (!migrated.containsKey('entry') && migrated.containsKey('in')) {
    migrated['entry'] = migrated['in'];
  }
  if (!migrated.containsKey('leave') && migrated.containsKey('out')) {
    migrated['leave'] = migrated['out'];
  }
  migrated.remove('in');
  migrated.remove('out');
  return migrated;
}

Map<String, dynamic> _clipExtra(Map<String, dynamic> json) {
  final extra = _unknown(json, {
    'id',
    'trackId',
    'mediaId',
    'label',
    'start',
    'duration',
    'sourceIn',
    'speed',
    'reverse',
    'volume',
    'pan',
    'mute',
    'fadeIn',
    'fadeOut',
    'linkedGroup',
    'effects',
    'blend',
    'transform',
    'text',
  });
  final legacy = extra.remove('imageAnim');
  final current = extra['clipAnim'];
  final animation = _migrateClipAnimation(current ?? legacy);
  if (animation != null) extra['clipAnim'] = animation;
  return extra;
}

/// Master output bus (AUD-10/11). The limiter is on by default: it exists to
/// stop an accidental over reaching the file, not to shape the mix.
class MasterBus {
  MasterBus({this.gain = 1.0, this.limiter = true, this.ceilingDb = -1.0});

  double gain;
  bool limiter;
  double ceilingDb;

  MasterBus copy() =>
      MasterBus(gain: gain, limiter: limiter, ceilingDb: ceilingDb);

  Map<String, dynamic> toJson() => {
    'gain': gain,
    'limiter': limiter,
    'ceilingDb': ceilingDb,
  };

  static MasterBus fromJson(Map<String, dynamic>? j) => MasterBus(
    gain: (j?['gain'] as num?)?.toDouble() ?? 1.0,
    limiter: (j?['limiter'] as bool?) ?? true,
    ceilingDb: (j?['ceilingDb'] as num?)?.toDouble() ?? -1.0,
  );
}

class SequenceSettings {
  SequenceSettings({
    required this.width,
    required this.height,
    required this.fps,
    this.audioSampleRate = 48000,
    this.background = '#000000',
    MasterBus? master,
  }) : master = master ?? MasterBus();

  int width;
  int height;
  String fps;
  int audioSampleRate;
  String background;

  /// Master bus: output fader and the safety limiter (AUD-10/11).
  MasterBus master;

  double get fpsValue => Rt.fpsFromString(fps);

  /// One frame of sequence time.
  Rt get frameDuration {
    final r = Rt.parse(fps);
    return Rt(r.den, r.num == 0 ? 1 : r.num);
  }

  SequenceSettings copy() => SequenceSettings(
    width: width,
    height: height,
    fps: fps,
    audioSampleRate: audioSampleRate,
    background: background,
    master: master.copy(),
  );

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'fps': fps,
    'audioSampleRate': audioSampleRate,
    'background': background,
    'master': master.toJson(),
  };

  static SequenceSettings fromJson(Map<String, dynamic> j) => SequenceSettings(
    width: j['width'] as int,
    height: j['height'] as int,
    fps: j['fps'] as String,
    audioSampleRate: (j['audioSampleRate'] as num?)?.toInt() ?? 48000,
    background: (j['background'] as String?) ?? '#000000',
    master: MasterBus.fromJson(j['master'] as Map<String, dynamic>?),
  );
}

enum ThumbStatus { none, pending, ready, failed }

class MediaAsset {
  MediaAsset({
    required this.id,
    required this.name,
    required this.path,
    required this.type,
    required this.duration,
    required this.hasAudio,
    this.hash = '',
    this.width,
    this.height,
    this.fps,
    this.rotation = 0,
    this.vfr = false,
    this.codec,
    this.hdr = 'none',
    this.bitrate,
    this.proxyPath,
    this.thumbStatus = ThumbStatus.none,
    this.offline = false,
    Map<String, dynamic>? extra,
  }) : extra = extra ?? {};

  factory MediaAsset.fromJson(Map<String, dynamic> j) {
    final probe = (j['probe'] as Map<String, dynamic>?) ?? const {};
    return MediaAsset(
      id: j['id'] as String,
      name: j['name'] as String,
      path: j['path'] as String,
      type: j['type'] as String,
      duration:
          j['duration'] == null ? Rt.zero() : Rt.parse(j['duration'] as String),
      hasAudio: (j['hasAudio'] as bool?) ?? false,
      hash: (j['hash'] as String?) ?? '',
      width: (probe['width'] as num?)?.toInt(),
      height: (probe['height'] as num?)?.toInt(),
      fps: probe['fps'] as String?,
      rotation: ((probe['rotation'] as num?) ?? 0).toInt(),
      vfr: (probe['vfr'] as bool?) ?? false,
      codec: probe['codec'] as String?,
      hdr: (probe['hdr'] as String?) ?? 'none',
      bitrate: (probe['bitrate'] as num?)?.toInt(),
      proxyPath: j['proxyPath'] as String?,
      thumbStatus:
          ThumbStatus.values.firstWhereOrNull(
            (s) => s.name == (j['thumbStatus'] as String?),
          ) ??
          ThumbStatus.none,
      extra: _unknown(j, {
        'id',
        'hash',
        'name',
        'path',
        'type',
        'duration',
        'hasAudio',
        'probe',
        'proxyPath',
        'thumbStatus',
      }),
    );
  }

  final String id;
  String name;
  String path;
  String type;
  Rt duration;
  bool hasAudio;
  String hash;
  int? width;
  int? height;
  String? fps;
  int rotation;
  bool vfr;
  String? codec;
  String hdr;
  int? bitrate;

  /// Set once a proxy render finishes (IMP-8).
  String? proxyPath;
  ThumbStatus thumbStatus;

  /// True when the file could not be resolved on open (IMP-15).
  bool offline;
  final Map<String, dynamic> extra;

  MediaAsset copy() => MediaAsset.fromJson(toJson())..offline = offline;

  /// Proxy rules from `01-architecture.md` §5.
  bool get wantsProxy {
    if (type != 'video') return false;
    if ((height ?? 0) > 1440) return true;
    if ((bitrate ?? 0) > 60000000) return true;
    final c = codec?.toLowerCase() ?? '';
    if (c.contains('hevc') || c.contains('h265') || c.contains('av1')) {
      return true;
    }
    return vfr;
  }

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'hash': hash,
    'name': name,
    'path': path,
    'type': type,
    if (!duration.isZero) 'duration': duration.toString(),
    'hasAudio': hasAudio,
    'probe': {
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      'rotation': rotation,
      if (fps != null) 'fps': fps,
      'vfr': vfr,
      if (codec != null) 'codec': codec,
      if (bitrate != null) 'bitrate': bitrate,
      'hdr': hdr,
      if (hasAudio) 'audio': 'stereo',
    },
    'proxyPath': proxyPath,
    'thumbStatus': thumbStatus.name,
  };
}

/// Track row heights offered by the header menu (TIM-2).
enum TrackHeight {
  small(48),
  medium(72),
  large(104);

  const TrackHeight(this.pixels);
  final double pixels;

  static TrackHeight nearest(int pixels) {
    var best = TrackHeight.medium;
    var delta = double.infinity;
    for (final h in TrackHeight.values) {
      final d = (h.pixels - pixels).abs();
      if (d < delta) {
        delta = d;
        best = h;
      }
    }
    return best;
  }
}

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

class Fade {
  Fade({Rt? duration, this.curve = 'linear'})
    : duration = duration ?? Rt.zero();

  Rt duration;
  String curve;

  Fade copy() => Fade(duration: duration, curve: curve);

  Map<String, dynamic> toJson() => {
    'duration': duration.toString(),
    'curve': curve,
  };

  static Fade fromJson(Map<String, dynamic>? j) => Fade(
    duration:
        j?['duration'] == null ? Rt.zero() : Rt.parse(j!['duration'] as String),
    curve: (j?['curve'] as String?) ?? 'linear',
  );
}

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

class Marker {
  Marker({
    required this.id,
    required this.time,
    this.name = '',
    this.color = '#F5C451',
  });

  factory Marker.fromJson(Map<String, dynamic> j) => Marker(
    id: j['id'] as String,
    time: Rt.parse(j['time'] as String),
    name: (j['name'] as String?) ?? '',
    color: (j['color'] as String?) ?? '#F5C451',
  );

  final String id;
  Rt time;
  String name;
  String color;

  Marker copy() => Marker(id: id, time: time, name: name, color: color);

  Map<String, dynamic> toJson() => {
    'id': id,
    'time': time.toString(),
    'name': name,
    'color': color,
  };
}

/// What the loader had to repair to satisfy §10 invariants.
class RepairReport {
  final List<String> issues = [];
  bool get isEmpty => issues.isEmpty;
}

class ProjectDoc {
  ProjectDoc({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.modifiedAt,
    required this.settings,
    Map<String, dynamic>? extra,
  }) : media = [],
       tracks = [],
       clips = [],
       markers = [],
       transitions = [],
       extra = extra ?? {};

  factory ProjectDoc.empty(
    String name, {
    int? width,
    int? height,
    double? fps,
  }) {
    return ProjectDoc(
      id: generateId(),
      name: name,
      createdAt: DateTime.now().toUtc(),
      modifiedAt: DateTime.now().toUtc(),
      settings: SequenceSettings(
        width: width ?? 1920,
        height: height ?? 1080,
        fps: Rt.fpsToString(fps ?? 30),
      ),
    ).._initDefaultTracks();
  }

  void _initDefaultTracks() {
    tracks.add(Track(id: generateId(), kind: 'video', name: 'V1', index: 0));
    tracks.add(
      Track(id: generateId(), kind: 'audio', name: 'A1', index: 0, height: 56),
    );
  }

  factory ProjectDoc.fromJson(Map<String, dynamic> j, {RepairReport? report}) {
    final doc = ProjectDoc(
      id: j['id'] as String,
      name: j['name'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      modifiedAt: DateTime.parse(j['modifiedAt'] as String),
      settings: SequenceSettings.fromJson(
        j['settings'] as Map<String, dynamic>,
      ),
      extra: _unknown(j, {
        'schema',
        'id',
        'name',
        'createdAt',
        'modifiedAt',
        'appVersion',
        'settings',
        'media',
        'tracks',
        'clips',
        'transitions',
        'markers',
      }),
    );
    void quarantine(String what, Object error) =>
        report?.issues.add('$what: $error');

    for (final m in (j['media'] as List<dynamic>? ?? const [])) {
      try {
        doc.media.add(MediaAsset.fromJson(m as Map<String, dynamic>));
      } catch (e) {
        quarantine('media', e);
      }
    }
    for (final t in (j['tracks'] as List<dynamic>? ?? const [])) {
      try {
        doc.tracks.add(Track.fromJson(t as Map<String, dynamic>));
      } catch (e) {
        quarantine('track', e);
      }
    }
    for (final c in (j['clips'] as List<dynamic>? ?? const [])) {
      try {
        doc.clips.add(Clip.fromJson(c as Map<String, dynamic>));
      } catch (e) {
        quarantine('clip', e);
      }
    }
    for (final tr in (j['transitions'] as List<dynamic>? ?? const [])) {
      try {
        doc.transitions.add(Transition.fromJson(tr as Map<String, dynamic>));
      } catch (e) {
        quarantine('transition', e);
      }
    }
    for (final m in (j['markers'] as List<dynamic>? ?? const [])) {
      try {
        doc.markers.add(Marker.fromJson(m as Map<String, dynamic>));
      } catch (e) {
        quarantine('marker', e);
      }
    }
    if (doc.tracks.isEmpty) doc._initDefaultTracks();
    doc._repair(report);
    return doc;
  }

  /// Drops references that cannot resolve and clamps impossible ranges (§10).
  void _repair(RepairReport? report) {
    final trackIds = tracks.map((t) => t.id).toSet();
    clips.removeWhere((c) {
      if (!trackIds.contains(c.trackId)) {
        report?.issues.add('clip ${c.label}: unknown track');
        return true;
      }
      if (c.duration <= Rt.zero()) {
        report?.issues.add('clip ${c.label}: non-positive duration');
        return true;
      }
      return false;
    });
    for (final c in clips) {
      if (c.start < Rt.zero()) {
        report?.issues.add('clip ${c.label}: negative start');
        c.start = Rt.zero();
      }
    }
    _repairTransitions(report);
    _repairParamValues(report);
  }

  static Rt _overlap(Clip a, Clip b) {
    final start = a.start > b.start ? a.start : b.start;
    final end = a.end < b.end ? a.end : b.end;
    final d = end.minus(start);
    return d > Rt.zero() ? d : Rt.zero();
  }

  void _repairTransitions(RepairReport? report) {
    // Transitions must reference clips on the same track and span exactly
    // their computed overlap (§5 Transition).
    final clipIds = {for (final c in clips) c.id: c};
    transitions.removeWhere((tr) {
      void drop(String reason) =>
          report?.issues.add('transition ${tr.id}: $reason');
      final a = clipIds[tr.aClipId];
      final b = clipIds[tr.bClipId];
      if (a == null || b == null) {
        drop('unknown clip');
      } else if (a.trackId != b.trackId) {
        drop('clips on different tracks');
      } else if (tr.duration <= Rt.zero()) {
        drop('non-positive duration');
      } else {
        final overlap = _overlap(a, b);
        if (overlap != tr.duration) {
          drop('duration ${tr.duration} != overlap $overlap');
        } else {
          return false;
        }
      }
      return true;
    });
  }

  /// Drops keyframes outside [0, clip.duration] or non-increasing, silently
  /// into the report like other repairs. O(n) over clips and their params.
  void _repairParamValues(RepairReport? report) {
    for (final c in clips) {
      ParamValue fix(String what, ParamValue pv) =>
          _repairedKeys(pv, what, c.duration, report);
      for (final fx in c.effects) {
        if (fx is! Map<String, dynamic>) continue;
        final params = fx['params'];
        if (params is! Map<String, dynamic>) continue;
        for (final entry in params.entries) {
          final v = entry.value;
          if (v is ParamValue) {
            params[entry.key] = fix('clip ${c.id} effect ${entry.key}', v);
          }
        }
      }
      final t = c.transform;
      if (t == null) continue;
      fix('clip ${c.id} transform x', t.x);
      fix('clip ${c.id} transform y', t.y);
      fix('clip ${c.id} transform scale', t.scale);
      fix('clip ${c.id} transform rotation', t.rotation);
      fix('clip ${c.id} transform anchor', t.anchor);
      fix('clip ${c.id} transform opacity', t.opacity);
    }
  }

  /// Returns [pv] unchanged when its keys are valid, otherwise a repaired copy.
  static ParamValue _repairedKeys(
    ParamValue pv,
    String what,
    Rt clipDuration,
    RepairReport? report,
  ) {
    if (!pv.animated) return pv;
    pv.sortKeys();
    Rt? lastT;
    var bad = false;
    for (final k in pv.keyframes) {
      final t = _keyTime(k['t']);
      if (t < Rt.zero() || t > clipDuration || (lastT != null && t <= lastT)) {
        k['__drop'] = true;
        bad = true;
      } else {
        lastT = t;
      }
    }
    if (!bad) return pv;
    report?.issues.add(
      '$what: dropped keyframe(s) outside span or non-increasing',
    );
    pv.keyframes.removeWhere((k) => k.remove('__drop') as bool? ?? false);
    return pv;
  }

  static Rt _keyTime(dynamic t) =>
      t is String
          ? Rt.parse(t)
          : (t is num ? Rt.fromSeconds(t.toDouble()) : Rt.zero());

  Transition? transitionById(String id) =>
      transitions.firstWhereOrNull((t) => t.id == id);

  factory ProjectDoc.decode(String contents, {RepairReport? report}) {
    final json = jsonDecode(contents) as Map<String, dynamic>;
    final schema = json['schema'] as String? ?? kSchemaVersion;
    final major = int.tryParse(schema.split('@').last) ?? 1;
    if (major > 1) {
      throw const FormatException(
        'This project was created in a newer version of CrazyCut',
      );
    }
    return ProjectDoc.fromJson(json, report: report);
  }

  final String id;
  String name;
  DateTime createdAt;
  DateTime modifiedAt;
  final SequenceSettings settings;
  final List<MediaAsset> media;
  final List<Track> tracks;
  final List<Clip> clips;
  final List<Marker> markers;
  final List<Transition> transitions;
  final Map<String, dynamic> extra;

  Rt get frameDuration => settings.frameDuration;

  List<Track> get videoTracks => tracks
      .where((t) => t.isVideo)
      .sorted((a, b) => a.index.compareTo(b.index));

  List<Track> get audioTracks => tracks
      .where((t) => !t.isVideo)
      .sorted((a, b) => a.index.compareTo(b.index));

  Track? videoTrack() => videoTracks.firstOrNull;
  Track? audioTrack() => audioTracks.firstOrNull;
  Track? trackById(String id) => tracks.firstWhereOrNull((t) => t.id == id);
  Clip? clipById(String id) => clips.firstWhereOrNull((c) => c.id == id);
  MediaAsset? assetById(String id) => media.firstWhereOrNull((m) => m.id == id);

  List<Clip> clipsOn(String trackId) => clips
      .where((c) => c.trackId == trackId)
      .sorted((a, b) => a.start.compareTo(b.start));

  /// Clips sharing [clip]'s linked group, including itself.
  List<Clip> linkedWith(Clip clip) {
    final group = clip.linkedGroup;
    if (group == null) return [clip];
    return clips.where((c) => c.linkedGroup == group).toList();
  }

  Rt get sequenceDuration {
    var end = Rt.zero();
    for (final c in clips) {
      if (c.end > end) end = c.end;
    }
    return end;
  }

  /// How many clips reference an asset (IMP-14).
  int usageCount(String mediaId) =>
      clips.where((c) => c.mediaId == mediaId).length;

  Map<String, dynamic> toJson() => {
    ...extra,
    'schema': kSchemaVersion,
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'modifiedAt': modifiedAt.toIso8601String(),
    'appVersion': '0.1.0',
    'settings': settings.toJson(),
    'media': media.map((m) => m.toJson()).toList(),
    'tracks': tracks.map((t) => t.toJson()).toList(),
    'clips': clips.map((c) => c.toJson()).toList(),
    'transitions': [for (final t in transitions) t.toJson()],
    'markers': markers.map((m) => m.toJson()).toList(),
  };

  String encode({bool touchModified = true}) {
    if (touchModified) modifiedAt = DateTime.now().toUtc();
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  /// Independent copy with fresh ids — Duplicate project (PRJ-2, criterion 3).
  ProjectDoc duplicate({String? name}) {
    final json =
        jsonDecode(encode(touchModified: false)) as Map<String, dynamic>;
    final copy = ProjectDoc.fromJson(json);
    final clone = ProjectDoc(
      id: generateId(),
      name: name ?? '${copy.name} copy',
      createdAt: DateTime.now().toUtc(),
      modifiedAt: DateTime.now().toUtc(),
      settings: copy.settings.copy(),
      extra: Map<String, dynamic>.from(copy.extra),
    );
    final trackIds = <String, String>{};
    final mediaIds = <String, String>{};
    for (final m in copy.media) {
      final fresh = m.copy();
      final id = generateId();
      mediaIds[m.id] = id;
      clone.media.add(MediaAsset.fromJson(fresh.toJson()..['id'] = id));
    }
    for (final t in copy.tracks) {
      final id = generateId();
      trackIds[t.id] = id;
      clone.tracks.add(Track.fromJson(t.toJson()..['id'] = id));
    }
    final groups = <String, String>{};
    final clipIds = <String, String>{};
    for (final c in copy.clips) {
      final json = c.toJson();
      json['id'] = generateId();
      json['trackId'] = trackIds[c.trackId];
      json['mediaId'] = mediaIds[c.mediaId] ?? c.mediaId;
      if (c.linkedGroup != null) {
        json['linkedGroup'] = groups.putIfAbsent(c.linkedGroup!, generateId);
      }
      clone.clips.add(Clip.fromJson(json));
      clipIds[c.id] = clone.clips.last.id;
    }
    for (final m in copy.markers) {
      clone.markers.add(
        Marker(id: generateId(), time: m.time, name: m.name, color: m.color),
      );
    }
    for (final tr in copy.transitions) {
      clone.transitions.add(
        tr.copy(
          id: generateId(),
          aClipId: clipIds[tr.aClipId] ?? tr.aClipId,
          bClipId: clipIds[tr.bClipId] ?? tr.bClipId,
        ),
      );
    }
    return clone;
  }
}
