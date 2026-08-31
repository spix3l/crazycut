part of 'template.dart';

/// The media a template needs, described well enough to re-find or re-import
/// it in another project (TPL-12).
class TemplateMediaRef {
  TemplateMediaRef({
    required this.id,
    required this.name,
    required this.path,
    required this.type,
    required this.duration,
    this.hash = '',
    this.hasAudio = false,
    this.sourceKind = MediaSourceKind.file,
    Map<String, dynamic>? probe,
  }) : probe = probe ?? {};

  factory TemplateMediaRef.fromJson(Map<String, dynamic> j) => TemplateMediaRef(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    path: (j['path'] as String?) ?? '',
    type: (j['type'] as String?) ?? 'video',
    duration:
        j['duration'] == null ? Rt.zero() : Rt.parse(j['duration'] as String),
    hash: (j['hash'] as String?) ?? '',
    hasAudio: (j['hasAudio'] as bool?) ?? false,
    sourceKind: MediaSourceKind.values.firstWhere(
      (kind) => kind.name == (j['sourceKind'] as String? ?? 'file'),
      orElse: () => MediaSourceKind.file,
    ),
    probe: (j['probe'] as Map<String, dynamic>?)?.cast<String, dynamic>(),
  );

  factory TemplateMediaRef.of(MediaAsset asset) => TemplateMediaRef(
    id: asset.id,
    name: asset.name,
    path: asset.path,
    type: asset.type,
    duration: asset.duration,
    hash: asset.hash,
    hasAudio: asset.hasAudio,
    sourceKind: asset.sourceKind,
    probe: (asset.toJson()['probe'] as Map<String, dynamic>?) ?? {},
  );

  final String id;
  final String name;
  final String path;
  final String type;
  final Rt duration;
  final String hash;
  final bool hasAudio;
  final MediaSourceKind sourceKind;
  final Map<String, dynamic> probe;

  /// The offline stand-in used when neither the hash nor the path resolves
  /// (TPL-12 case 3): a real asset entry, so the relink flow can repair it.
  MediaAsset toOfflineAsset(String id) => MediaAsset.fromJson({
    'id': id,
    'hash': hash,
    'name': name,
    'path': path,
    'type': type,
    if (!duration.isZero) 'duration': duration.toString(),
    'hasAudio': hasAudio,
    'probe': probe,
    'thumbStatus': 'none',
    if (sourceKind != MediaSourceKind.file) 'sourceKind': sourceKind.name,
  })..offline = true;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'type': type,
    if (!duration.isZero) 'duration': duration.toString(),
    'hash': hash,
    'hasAudio': hasAudio,
    if (sourceKind != MediaSourceKind.file) 'sourceKind': sourceKind.name,
    'probe': probe,
  };
}
