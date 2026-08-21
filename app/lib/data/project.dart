import 'dart:convert';

import 'package:collection/collection.dart';

import 'package:crazycut_app/models/rational.dart';

const String kSchemaVersion = 'crazycut/project@1';

String generateId() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final r = DateTime.now().microsecondsSinceEpoch;
  String hex8(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return '${hex8(now >> 16)}-${hex8((now << 16) | (r & 0xFFFF))}-4${hex8(r >> 16).substring(1)}'
      '-a${hex8(r ^ now).substring(0, 3)}-'
      '${hex8(r * 7 + now)}${hex8(now * 31 + r)}'.substring(0, 36);
}

class SequenceSettings {
  SequenceSettings({
    required this.width,
    required this.height,
    required this.fps,
    this.audioSampleRate = 48000,
    this.background = '#000000',
  });

  int width;
  int height;
  String fps;
  int audioSampleRate;
  String background;

  double get fpsValue => Rt.fpsFromString(fps);

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
        'fps': fps,
        'audioSampleRate': audioSampleRate,
        'background': background,
      };

  static SequenceSettings fromJson(Map<String, dynamic> j) => SequenceSettings(
        width: j['width'] as int,
        height: j['height'] as int,
        fps: j['fps'] as String,
        audioSampleRate: (j['audioSampleRate'] as num?)?.toInt() ?? 48000,
        background: (j['background'] as String?) ?? '#000000',
      );
}

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
  });

  factory MediaAsset.fromJson(Map<String, dynamic> j) => MediaAsset(
        id: j['id'] as String,
        name: j['name'] as String,
        path: j['path'] as String,
        type: j['type'] as String,
        duration:
            j['duration'] == null ? Rt.zero() : Rt.parse(j['duration'] as String),
        hasAudio: (j['hasAudio'] as bool?) ?? false,
        hash: (j['hash'] as String?) ?? '',
        width: (j['probe']?['width'] as num?)?.toInt(),
        height: (j['probe']?['height'] as num?)?.toInt(),
        fps: j['probe']?['fps'] as String?,
        rotation: ((j['probe']?['rotation'] as num?) ?? 0).toInt(),
        vfr: (j['probe']?['vfr'] as bool?) ?? false,
        codec: j['probe']?['codec'] as String?,
        hdr: (j['probe']?['hdr'] as String?) ?? 'none',
      );

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

  Map<String, dynamic> toJson() => {
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
          'hdr': hdr,
          if (hasAudio) 'audio': 'stereo',
        },
        'proxyPath': null,
        'thumbStatus': 'ready',
      };
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
    this.height = 80,
  });

  final String id;
  final String kind;
  final String name;
  final int index;
  final bool mute;
  final bool solo;
  final bool lock;
  final bool hidden;
  final int height;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'name': name,
        'index': index,
        'mute': mute,
        'solo': solo,
        'lock': lock,
        'hidden': hidden,
        'height': height,
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
        height: (j['height'] as num?)?.toInt() ?? 80,
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
  });

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
      );

  final String id;
  final String trackId;
  final String mediaId;
  final String label;
  Rt start;
  Rt duration;
  Rt sourceIn;
  final String speed;

  Map<String, dynamic> toJson() => {
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
        'volume': 1.0,
        'mute': false,
        'fadeIn': {'duration': '0/1', 'curve': 'linear'},
        'fadeOut': {'duration': '0/1', 'curve': 'linear'},
        'effects': [],
      };
}

class ProjectDoc {
  ProjectDoc({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.modifiedAt,
    required this.settings,
  })  : media = [],
        tracks = [],
        clips = [];

  factory ProjectDoc.empty(String name, {int? width, int? height, double? fps}) {
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
    tracks.add(Track(id: generateId(), kind: 'audio', name: 'A1', index: 0));
  }

  factory ProjectDoc.fromJson(Map<String, dynamic> j) {
    final doc = ProjectDoc(
      id: j['id'] as String,
      name: j['name'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      modifiedAt: DateTime.parse(j['modifiedAt'] as String),
      settings: SequenceSettings.fromJson(j['settings'] as Map<String, dynamic>),
    );
    doc.media.addAll((j['media'] as List<dynamic>? ?? [])
        .map((m) => MediaAsset.fromJson(m as Map<String, dynamic>)));
    doc.tracks.addAll((j['tracks'] as List<dynamic>? ?? [])
        .map((t) => Track.fromJson(t as Map<String, dynamic>)));
    doc.clips.addAll((j['clips'] as List<dynamic>? ?? [])
        .map((c) => Clip.fromJson(c as Map<String, dynamic>)));
    if (doc.tracks.isEmpty) doc._initDefaultTracks();
    return doc;
  }

  factory ProjectDoc.decode(String contents) =>
      ProjectDoc.fromJson(jsonDecode(contents) as Map<String, dynamic>);

  final String id;
  String name;
  DateTime createdAt;
  DateTime modifiedAt;
  final SequenceSettings settings;
  final List<MediaAsset> media;
  final List<Track> tracks;
  final List<Clip> clips;

  Track? videoTrack() =>
      tracks.where((t) => t.kind == 'video').toList().firstOrNull;

  Track? audioTrack() =>
      tracks.where((t) => t.kind == 'audio').toList().firstOrNull;

  MediaAsset? assetById(String id) =>
      media.where((m) => m.id == id).toList().firstOrNull;

  Rt get sequenceDuration {
    var end = Rt.zero();
    for (final c in clips) {
      final clipEnd = c.start.plus(c.duration);
      if (clipEnd > end) end = clipEnd;
    }
    return end;
  }

  String encode() {
    modifiedAt = DateTime.now().toUtc();
    return const JsonEncoder.withIndent('  ').convert({
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
      'transitions': [],
      'markers': [],
    });
  }
}
