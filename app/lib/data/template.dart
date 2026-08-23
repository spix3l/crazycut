import 'dart:convert';

import 'package:collection/collection.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/transition.dart';
import 'package:crazycut_app/models/rational.dart';

/// Schema id of a `.cctemplate` file (`03-features/templates.md` TPL-1).
const String kTemplateSchema = 'crazycut/template@1';

/// File extension of a saved template.
const String kTemplateExtension = 'cctemplate';

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
    duration: j?['duration'] == null
        ? null
        : Rt.parse(j!['duration'] as String),
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

/// A lane of the template, addressed by offset instead of by track id so the
/// chunk lands correctly in a project with a different track layout (TPL-11).
class TemplateLane {
  TemplateLane({
    required this.key,
    required this.kind,
    required this.offset,
    this.name = '',
  });

  factory TemplateLane.fromJson(Map<String, dynamic> j) => TemplateLane(
    key: j['key'] as String,
    kind: (j['kind'] as String?) ?? 'video',
    offset: ((j['offset'] as num?) ?? 0).toInt(),
    name: (j['name'] as String?) ?? '',
  );

  /// Template-local id, referenced by the captured clips' `trackId`.
  final String key;
  final String kind;

  /// Lanes above the template's base lane of the same kind; 0 is the base.
  final int offset;
  final String name;

  bool get isVideo => kind == 'video';

  Map<String, dynamic> toJson() => {
    'key': key,
    'kind': kind,
    'offset': offset,
    if (name.isNotEmpty) 'name': name,
  };
}

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
    Map<String, dynamic>? probe,
  }) : probe = probe ?? {};

  factory TemplateMediaRef.fromJson(Map<String, dynamic> j) => TemplateMediaRef(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    path: (j['path'] as String?) ?? '',
    type: (j['type'] as String?) ?? 'video',
    duration: j['duration'] == null
        ? Rt.zero()
        : Rt.parse(j['duration'] as String),
    hash: (j['hash'] as String?) ?? '',
    hasAudio: (j['hasAudio'] as bool?) ?? false,
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
    probe: (asset.toJson()['probe'] as Map<String, dynamic>?) ?? {},
  );

  final String id;
  final String name;
  final String path;
  final String type;
  final Rt duration;
  final String hash;
  final bool hasAudio;
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
  })..offline = true;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'type': type,
    if (!duration.isZero) 'duration': duration.toString(),
    'hash': hash,
    'hasAudio': hasAudio,
    'probe': probe,
  };
}

/// A reusable chunk of timeline (`03-features/templates.md`).
///
/// Clip and transition payloads are stored as raw JSON in the project's own
/// encoding: a template is a fragment of a document, and keeping the fragment
/// in document shape means every clip feature — effects, text, keyframes,
/// blend modes — travels with it for free, including ones added later.
class ClipTemplate {
  ClipTemplate({
    required this.id,
    required this.name,
    required this.createdAt,
    this.description = '',
    this.category = '',
    this.width = 0,
    this.height = 0,
    this.fps = '',
    List<TemplateLane>? lanes,
    List<Map<String, dynamic>>? clips,
    List<Map<String, dynamic>>? transitions,
    List<TemplateMediaRef>? media,
    List<TemplateSlot>? slots,
    TemplateEdge? edgeIn,
    TemplateEdge? edgeOut,
    this.filePath,
  }) : lanes = lanes ?? [],
       clips = clips ?? [],
       transitions = transitions ?? [],
       media = media ?? [],
       slots = slots ?? [],
       edgeIn = edgeIn ?? TemplateEdge(),
       edgeOut = edgeOut ?? TemplateEdge();

  factory ClipTemplate.fromJson(Map<String, dynamic> j, {String? filePath}) {
    final schema = j['schema'] as String? ?? kTemplateSchema;
    final major = int.tryParse(schema.split('@').last) ?? 1;
    if (major > 1) {
      throw const FormatException(
        'This template was created in a newer version of CrazyCut',
      );
    }
    return ClipTemplate(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? 'Template',
      description: (j['description'] as String?) ?? '',
      category: (j['category'] as String?) ?? '',
      createdAt:
          DateTime.tryParse((j['createdAt'] as String?) ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
      width: ((j['width'] as num?) ?? 0).toInt(),
      height: ((j['height'] as num?) ?? 0).toInt(),
      fps: (j['fps'] as String?) ?? '',
      lanes: [
        for (final l in (j['lanes'] as List<dynamic>? ?? const []))
          TemplateLane.fromJson(l as Map<String, dynamic>),
      ],
      clips: [
        for (final c in (j['clips'] as List<dynamic>? ?? const []))
          (c as Map).cast<String, dynamic>(),
      ],
      transitions: [
        for (final t in (j['transitions'] as List<dynamic>? ?? const []))
          (t as Map).cast<String, dynamic>(),
      ],
      media: [
        for (final m in (j['media'] as List<dynamic>? ?? const []))
          TemplateMediaRef.fromJson(m as Map<String, dynamic>),
      ],
      slots: [
        for (final s in (j['slots'] as List<dynamic>? ?? const []))
          TemplateSlot.fromJson(s as Map<String, dynamic>),
      ],
      edgeIn: TemplateEdge.fromJson(j['edgeIn'] as Map<String, dynamic>?),
      edgeOut: TemplateEdge.fromJson(j['edgeOut'] as Map<String, dynamic>?),
      filePath: filePath,
    );
  }

  factory ClipTemplate.decode(String contents, {String? filePath}) =>
      ClipTemplate.fromJson(
        jsonDecode(contents) as Map<String, dynamic>,
        filePath: filePath,
      );

  final String id;
  String name;
  String description;
  String category;
  final DateTime createdAt;

  /// Sequence the template was authored in — used to warn about a frame-size
  /// mismatch, never to refuse an insert.
  int width;
  int height;
  String fps;

  final List<TemplateLane> lanes;
  final List<Map<String, dynamic>> clips;
  final List<Map<String, dynamic>> transitions;
  final List<TemplateMediaRef> media;
  final List<TemplateSlot> slots;
  TemplateEdge edgeIn;
  TemplateEdge edgeOut;

  /// Where the template was loaded from; null for a draft not yet saved.
  String? filePath;

  /// The chunk's span: every captured clip starts at 0 or later, so this is
  /// the largest end among them.
  Rt get duration {
    var end = Rt.zero();
    for (final json in clips) {
      final clipEnd = startOf(json).plus(durationOf(json));
      if (clipEnd > end) end = clipEnd;
    }
    return end;
  }

  /// Start of a stored clip payload, relative to the template's origin.
  static Rt startOf(Map<String, dynamic> json) =>
      Rt.parse((json['start'] as String?) ?? '0/1');

  static Rt durationOf(Map<String, dynamic> json) =>
      Rt.parse((json['duration'] as String?) ?? '0/1');

  TemplateLane? laneByKey(String key) =>
      lanes.firstWhereOrNull((l) => l.key == key);

  TemplateMediaRef? mediaById(String id) =>
      media.firstWhereOrNull((m) => m.id == id);

  /// The base video lane's clips in time order — what the edge transitions
  /// attach to (TPL-8).
  List<Map<String, dynamic>> get baseLaneClips {
    final base = lanes.firstWhereOrNull((l) => l.isVideo && l.offset == 0);
    if (base == null) return const [];
    return clips.where((c) => c['trackId'] == base.key).toList()
      ..sort((a, b) => startOf(a).compareTo(startOf(b)));
  }

  ClipTemplate copy({String? id, String? name}) => ClipTemplate.fromJson(
    toJson()
      ..['id'] = id ?? this.id
      ..['name'] = name ?? this.name,
  );

  Map<String, dynamic> toJson() => {
    'schema': kTemplateSchema,
    'id': id,
    'name': name,
    'description': description,
    'category': category,
    'createdAt': createdAt.toIso8601String(),
    'appVersion': '0.1.0',
    'width': width,
    'height': height,
    'fps': fps,
    'duration': duration.toString(),
    'lanes': [for (final l in lanes) l.toJson()],
    'clips': clips,
    'transitions': transitions,
    'media': [for (final m in media) m.toJson()],
    'slots': [for (final s in slots) s.toJson()],
    'edgeIn': edgeIn.toJson(),
    'edgeOut': edgeOut.toJson(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}
