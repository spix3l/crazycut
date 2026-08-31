part of 'template.dart';

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
