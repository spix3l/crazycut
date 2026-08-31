part of 'project.dart';

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
    this.sourceKind = MediaSourceKind.file,
    this.remoteEtag,
    this.remoteLastModified,
    this.remoteContentLength,
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
      sourceKind:
          MediaSourceKind.values.firstWhereOrNull(
            (kind) => kind.name == j['sourceKind'],
          ) ??
          MediaSourceKind.file,
      remoteEtag: (j['remote'] as Map<String, dynamic>?)?['etag'] as String?,
      remoteLastModified:
          (j['remote'] as Map<String, dynamic>?)?['lastModified'] as String?,
      remoteContentLength:
          ((j['remote'] as Map<String, dynamic>?)?['contentLength'] as num?)
              ?.toInt(),
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
        'sourceKind',
        'remote',
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
  MediaSourceKind sourceKind;
  String? remoteEtag;
  String? remoteLastModified;
  int? remoteContentLength;

  bool get isRemote => sourceKind == MediaSourceKind.url;

  String get remoteRevision => [
    remoteEtag ?? '',
    remoteLastModified ?? '',
    remoteContentLength?.toString() ?? '',
  ].join('|');

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
    if (sourceKind != MediaSourceKind.file) 'sourceKind': sourceKind.name,
    if (isRemote)
      'remote': {
        if (remoteEtag != null) 'etag': remoteEtag,
        if (remoteLastModified != null) 'lastModified': remoteLastModified,
        if (remoteContentLength != null) 'contentLength': remoteContentLength,
      },
  };
}
