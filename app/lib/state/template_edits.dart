import 'dart:convert';

import 'package:collection/collection.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/template.dart';
import 'package:crazycut_app/data/transition.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

/// What an insert produced, plus everything it had to work around (TPL-9/13).
class TemplateInsertResult {
  const TemplateInsertResult({
    required this.clipIds,
    required this.warnings,
    this.edgeInId,
    this.edgeOutId,
  });

  final List<String> clipIds;

  /// Non-fatal: an edge with no handles, a clamped duration, offline media.
  /// The insert completed regardless (TPL-9).
  final List<String> warnings;

  final String? edgeInId;
  final String? edgeOutId;

  bool get isEmpty => clipIds.isEmpty;
}

/// Reusable-template capture and insertion (`03-features/templates.md`).
///
/// Split from [TimelineEdits] the way [AudioEdits] is: templates are a way of
/// *replaying* timeline operations, so everything here goes through the same
/// public ops and the same command stack. An insert opens one gesture, so
/// media resolution, clips, internal transitions, slot values and both edges
/// collapse into a single undo step (TPL-14).
mixin TemplateEdits on TimelineEdits {
  // --- Capture (TPL-4/5) ----------------------------------------------------

  /// Builds a template draft from [clipIds] (default: the selection). Returns
  /// null when there is nothing to capture. The draft is not saved: the save
  /// dialog edits its name, slots and edges first.
  ClipTemplate? captureTemplate({
    required String name,
    Iterable<String>? clipIds,
    String description = '',
    String category = '',
  }) {
    final source = (clipIds ?? selection)
        .map(doc.clipById)
        .whereType<Clip>()
        .sorted((a, b) => a.start.compareTo(b.start));
    if (source.isEmpty) return null;

    final origin = source.map((c) => c.start).reduce((a, b) => a < b ? a : b);
    final lanes = _captureLanes(source);
    final ids = source.map((c) => c.id).toSet();

    final clips = <Map<String, dynamic>>[];
    for (final clip in source) {
      final json = _deepCopy(clip.toJson());
      json['start'] = clip.start.minus(origin).toString();
      clips.add(json);
    }

    // Only transitions with both sides inside the selection: a half-captured
    // transition owns geometry on a clip that is not coming along.
    final transitions = [
      for (final tr in doc.transitions)
        if (ids.contains(tr.aClipId) && ids.contains(tr.bClipId))
          _deepCopy(tr.toJson()),
    ];

    final media = <TemplateMediaRef>[
      for (final id in source.map((c) => c.mediaId).toSet())
        if (id.isNotEmpty && doc.assetById(id) != null)
          TemplateMediaRef.of(doc.assetById(id)!),
    ];

    final template = ClipTemplate(
      id: generateId(),
      name: name.trim().isEmpty ? 'Template' : name.trim(),
      description: description,
      category: category,
      createdAt: DateTime.now().toUtc(),
      width: doc.settings.width,
      height: doc.settings.height,
      fps: doc.settings.fps,
      lanes: lanes,
      clips: clips,
      transitions: transitions,
      media: media,
    );
    template.slots.addAll(_proposeSlots(template));
    return template;
  }

  /// Lane offsets relative to the lowest captured lane of each kind, so the
  /// chunk keeps its internal stacking wherever it lands (TPL-4).
  List<TemplateLane> _captureLanes(List<Clip> source) {
    final tracks = source
        .map((c) => trackById(c.trackId))
        .whereType<Track>()
        .toSet()
        .toList();
    int baseIndex(bool video) {
      final peers = tracks.where((t) => t.isVideo == video);
      if (peers.isEmpty) return 0;
      return peers.map((t) => t.index).reduce((a, b) => a < b ? a : b);
    }

    final videoBase = baseIndex(true);
    final audioBase = baseIndex(false);
    return [
      for (final t in tracks)
        TemplateLane(
          key: t.id,
          kind: t.kind,
          offset: t.index - (t.isVideo ? videoBase : audioBase),
          name: t.name,
        ),
    ]..sort((a, b) => a.offset.compareTo(b.offset));
  }

  /// The parts an insert may change (TPL-5). Every candidate is proposed; the
  /// save dialog is where the author drops the ones they do not want.
  List<TemplateSlot> _proposeSlots(ClipTemplate template) {
    final slots = <TemplateSlot>[];
    for (final json in template.clips) {
      final text = json['text'] as Map<String, dynamic>?;
      if (text != null) {
        final content = (text['content'] as String?) ?? '';
        slots.add(
          TemplateSlot(
            id: generateId(),
            kind: SlotKind.text,
            name: _slotLabel(content, fallback: 'Title'),
            clipId: json['id'] as String,
            defaultValue: content,
            hint: 'Text shown by this clip',
          ),
        );
        continue;
      }
      final mediaId = (json['mediaId'] as String?) ?? '';
      if (mediaId.isEmpty) continue;
      final ref = template.mediaById(mediaId);
      slots.add(
        TemplateSlot(
          id: generateId(),
          kind: SlotKind.media,
          name: ref?.name ?? 'Clip',
          clipId: json['id'] as String,
          defaultValue: ref?.name ?? '',
          hint: 'Swap the footage this clip uses',
        ),
      );
    }
    slots.add(
      TemplateSlot(
        id: generateId(),
        kind: SlotKind.duration,
        name: 'Duration',
        defaultValue: template.duration.seconds.toStringAsFixed(2),
        hint: 'Total length in seconds',
      ),
    );
    return slots;
  }

  /// First line of the text, trimmed to something a form label can show.
  static String _slotLabel(String content, {required String fallback}) {
    final line = content
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
        .trim();
    if (line.isEmpty) return fallback;
    return line.length <= 24 ? line : '${line.substring(0, 24)}…';
  }

  // --- Insert (TPL-11..15) --------------------------------------------------

  /// Drops [template] onto the timeline.
  ///
  /// [mediaResolution] maps template media ref ids to assets already in the
  /// project; anything unmapped falls back to an offline stand-in carrying the
  /// recorded probe data, so an insert never blocks on missing files (TPL-12).
  /// [slotValues] is keyed by slot id: text content, a project asset id, or
  /// seconds for the duration slot.
  TemplateInsertResult insertTemplate(
    ClipTemplate template, {
    Rt? at,
    String? baseTrackId,
    Map<String, String> slotValues = const {},
    Map<String, String> mediaResolution = const {},
    DropMode mode = DropMode.insert,
    TemplateEdge? edgeIn,
    TemplateEdge? edgeOut,
  }) {
    if (template.clips.isEmpty) {
      return const TemplateInsertResult(clipIds: [], warnings: []);
    }
    final warnings = <String>[];
    if (template.width > 0 &&
        (template.width != doc.settings.width ||
            template.height != doc.settings.height)) {
      warnings.add(
        'Authored at ${template.width}×${template.height}, this sequence is '
        '${doc.settings.width}×${doc.settings.height}',
      );
    }

    final scale = _durationScale(template, slotValues, warnings);
    final origin = quantiseToFrame(at ?? playhead);
    final span = _scaled(template.duration, scale).atLeast(frameDuration);

    // One gesture around everything: nested ops adopt the open transaction,
    // so the whole insert lands as a single undo step (TPL-14).
    beginGesture('Insert template');
    final created = <String>[];
    String? edgeInId;
    String? edgeOutId;
    try {
      final assets = _resolveMedia(template, mediaResolution, warnings);
      final tracks = _resolveLanes(template, baseTrackId);
      if (tracks.isEmpty) {
        return const TemplateInsertResult(clipIds: [], warnings: []);
      }
      final baseTrack = tracks[_baseLaneKey(template)];

      final before = baseTrack == null
          ? null
          : _neighbourBefore(baseTrack.id, origin);
      final after = baseTrack == null
          ? null
          : _neighbourAfter(baseTrack.id, origin);

      switch (mode) {
        case DropMode.insert:
          _rippleForInsert(origin, span);
        case DropMode.overwrite:
          runEdit('Make room', (tx) {
            for (final track in tracks.values) {
              clearRangeIn(tx, track.id, origin, origin.plus(span));
            }
          });
        case DropMode.append:
          break;
      }

      final idMap = <String, String>{};
      runEdit('Insert template', (tx) {
        final groups = <String, String>{};
        for (final json in template.clips) {
          final lane = tracks[json['trackId'] as String? ?? ''];
          if (lane == null || lane.lock) continue;
          final copy = _deepCopy(json);
          final sourceId = copy['id'] as String;
          final clipId = generateId();
          idMap[sourceId] = clipId;
          copy['id'] = clipId;
          copy['trackId'] = lane.id;
          copy['start'] = origin
              .plus(_scaled(ClipTemplate.startOf(json), scale))
              .toString();
          copy['duration'] = _scaled(
            ClipTemplate.durationOf(json),
            scale,
          ).atLeast(frameDuration).toString();
          copy['mediaId'] = assets[copy['mediaId'] as String? ?? ''] ?? '';
          final group = copy['linkedGroup'] as String?;
          if (group != null) {
            copy['linkedGroup'] = groups.putIfAbsent(group, generateId);
          }
          _applySlots(template, slotValues, sourceId, copy, warnings);
          // Touch before insert so the delta's before-side is null and undo
          // removes the clip instead of restoring it.
          tx.clip(clipId);
          doc.clips.add(Clip.fromJson(copy));
          created.add(clipId);
        }

        // Internal transitions keep their authored geometry: the captured
        // clips already carry the overlap, so re-deriving handles here would
        // extend them a second time (TPL-7).
        for (final json in template.transitions) {
          final a = idMap[json['aClipId'] as String? ?? ''];
          final b = idMap[json['bClipId'] as String? ?? ''];
          if (a == null || b == null) continue;
          final copy = _deepCopy(json);
          copy['id'] = generateId();
          copy['aClipId'] = a;
          copy['bClipId'] = b;
          for (final key in ['duration', 'aExtend', 'bExtend']) {
            final value = copy[key] as String?;
            if (value != null) {
              copy[key] = _scaled(Rt.parse(value), scale).toString();
            }
          }
          tx.transition(copy['id'] as String);
          doc.transitions.add(Transition.fromJson(copy));
        }
      });

      if (created.isEmpty) {
        return TemplateInsertResult(clipIds: const [], warnings: warnings);
      }

      // Edges run the normal transition path, so handles, alignment fallback
      // and refusals behave exactly as a hand-made transition (TPL-8/9).
      final base = baseTrack == null
          ? const <Clip>[]
          : created
                .map(doc.clipById)
                .whereType<Clip>()
                .where((c) => c.trackId == baseTrack.id)
                .sorted((a, b) => a.start.compareTo(b.start));
      if (base.isNotEmpty) {
        edgeInId = _applyEdge(
          edgeIn ?? template.edgeIn,
          before,
          base.first,
          'in',
          warnings,
        );
        edgeOutId = _applyEdge(
          edgeOut ?? template.edgeOut,
          base.last,
          after,
          'out',
          warnings,
        );
      }

      selection
        ..clear()
        ..addAll(created);
    } finally {
      endGesture();
    }

    return TemplateInsertResult(
      clipIds: created,
      warnings: warnings,
      edgeInId: edgeInId,
      edgeOutId: edgeOutId,
    );
  }

  /// Insert mode is a real insert edit: every unlocked lane opens up by the
  /// template's span so nothing downstream loses sync. Clips straddling the
  /// insertion point are split there first.
  void _rippleForInsert(Rt origin, Rt span) {
    runEdit('Make room', (tx) {
      for (final track in doc.tracks) {
        if (track.lock) continue;
        for (final clip in doc.clipsOn(track.id).toList()) {
          if (clip.start < origin && clip.end > origin) {
            splitClip(clip, origin);
          }
        }
        for (final clip in doc.clipsOn(track.id)) {
          if (clip.start >= origin) {
            tx.clip(clip.id);
            clip.start = clip.start.plus(span);
          }
        }
      }
    });
  }

  /// Applies one edge spec; a missing neighbour is silently skipped, a refusal
  /// becomes a warning and the insert continues (TPL-9).
  String? _applyEdge(
    TemplateEdge edge,
    Clip? a,
    Clip? b,
    String side,
    List<String> warnings,
  ) {
    if (!edge.enabled || a == null || b == null) return null;
    final id = addTransition(
      a.id,
      b.id,
      type: edge.type,
      duration: edge.duration,
    );
    if (id == null) {
      warnings.add(
        '${side == 'in' ? 'Opening' : 'Closing'} transition skipped — '
        '${lastTransitionError ?? 'not possible at this cut'}',
      );
    }
    return id;
  }

  Clip? _neighbourBefore(String trackId, Rt at) {
    Clip? best;
    for (final c in doc.clipsOn(trackId)) {
      if (c.end <= at && (best == null || c.end > best.end)) best = c;
    }
    return best;
  }

  Clip? _neighbourAfter(String trackId, Rt at) {
    for (final c in doc.clipsOn(trackId)) {
      if (c.start >= at) return c;
    }
    return null;
  }

  String _baseLaneKey(ClipTemplate template) =>
      template.lanes.firstWhereOrNull((l) => l.isVideo && l.offset == 0)?.key ??
      (template.lanes.isEmpty ? '' : template.lanes.first.key);

  /// Template media ref id → project asset id, creating offline stand-ins for
  /// anything the caller could not resolve (TPL-12 case 3).
  Map<String, String> _resolveMedia(
    ClipTemplate template,
    Map<String, String> resolution,
    List<String> warnings,
  ) {
    final map = <String, String>{};
    for (final ref in template.media) {
      final supplied = resolution[ref.id];
      if (supplied != null && doc.assetById(supplied) != null) {
        map[ref.id] = supplied;
        continue;
      }
      final known = doc.media.firstWhereOrNull(
        (a) =>
            (ref.hash.isNotEmpty && a.hash == ref.hash) ||
            (ref.path.isNotEmpty && a.path == ref.path),
      );
      if (known != null) {
        map[ref.id] = known.id;
        continue;
      }
      // Media entries are not part of the undo deltas, so undoing an insert
      // leaves this stand-in in the pool. That is deliberate: it keeps the
      // relink flow able to repair a template whose files moved.
      final asset = ref.toOfflineAsset(generateId());
      doc.media.add(asset);
      map[ref.id] = asset.id;
      warnings.add('${ref.name} is offline — relink to see it');
    }
    return map;
  }

  /// Template lane key → project track, creating lanes as needed (TPL-11).
  Map<String, Track> _resolveLanes(ClipTemplate template, String? baseTrackId) {
    Track? baseVideo = trackById(baseTrackId);
    if (baseVideo == null || !baseVideo.isVideo) {
      baseVideo =
          doc.videoTracks.reversed.firstWhereOrNull((t) => !t.lock) ??
          doc.videoTrack();
    }
    final baseAudio = doc.audioTracks.firstOrNull;
    final result = <String, Track>{};
    for (final lane in template.lanes) {
      final wanted = (lane.isVideo ? baseVideo?.index : baseAudio?.index) ?? 0;
      final track = _trackAt(lane.kind, wanted + lane.offset);
      if (track != null) result[lane.key] = track;
    }
    return result;
  }

  /// The track of [kind] at [index], adding lanes until it exists.
  Track? _trackAt(String kind, int index) {
    if (index < 0) return null;
    Track? found() =>
        doc.tracks.firstWhereOrNull((t) => t.kind == kind && t.index == index);
    var existing = found();
    var guard = 0;
    while (existing == null && guard++ < 16) {
      runEdit('Add track', (tx) => addTrackIn(tx, kind));
      existing = found();
    }
    return existing;
  }

  /// Proportional retime factor from the duration slot, 1.0 when absent.
  double _durationScale(
    ClipTemplate template,
    Map<String, String> slotValues,
    List<String> warnings,
  ) {
    final slot = template.slots.firstWhereOrNull(
      (s) => s.kind == SlotKind.duration,
    );
    if (slot == null) return 1.0;
    final wanted = double.tryParse(slotValues[slot.id] ?? '');
    final authored = template.duration.seconds;
    if (wanted == null || wanted <= 0 || authored <= 0) return 1.0;
    final scale = wanted / authored;
    if ((scale - 1).abs() < 0.0001) return 1.0;
    if (scale > 1) {
      warnings.add(
        'Stretched to ${wanted.toStringAsFixed(2)} s — clip animations keep '
        'their authored timing',
      );
    }
    return scale;
  }

  Rt _scaled(Rt value, double scale) =>
      scale == 1.0 ? value : Rt.fromMicros((value.micros * scale).round());

  /// Writes the slot values that belong to one clip (TPL-13).
  void _applySlots(
    ClipTemplate template,
    Map<String, String> slotValues,
    String sourceClipId,
    Map<String, dynamic> copy,
    List<String> warnings,
  ) {
    for (final slot in template.slots) {
      if (slot.clipId != sourceClipId) continue;
      final value = slotValues[slot.id];
      if (value == null || value.isEmpty) continue;
      switch (slot.kind) {
        case SlotKind.text:
          final text = copy['text'];
          if (text is Map<String, dynamic>) text['content'] = value;
        case SlotKind.media:
          final asset = doc.assetById(value);
          if (asset == null) break;
          copy['mediaId'] = asset.id;
          copy['label'] = asset.name;
          _clampToSource(copy, asset, warnings);
        case SlotKind.duration:
          break;
      }
    }
    final asset = doc.assetById(copy['mediaId'] as String? ?? '');
    if (asset != null) _clampToSource(copy, asset, warnings);
  }

  /// Keeps `sourceIn + duration × speed` inside the asset (§10 invariant 1),
  /// which a swapped-in shorter clip would otherwise break.
  void _clampToSource(
    Map<String, dynamic> copy,
    MediaAsset asset,
    List<String> warnings,
  ) {
    if (asset.duration.isZero || asset.type == 'image') return;
    final clip = Clip.fromJson(copy);
    final speed = clip.speedValue <= 0 ? 1.0 : clip.speedValue;
    var sourceIn = clip.sourceIn;
    if (sourceIn >= asset.duration) sourceIn = Rt.zero();
    final available = asset.duration.minus(sourceIn);
    final maxDuration = Rt.fromMicros((available.micros / speed).round());
    if (clip.duration <= maxDuration && sourceIn == clip.sourceIn) return;
    copy['sourceIn'] = sourceIn.toString();
    if (clip.duration > maxDuration) {
      copy['duration'] = maxDuration.atLeast(frameDuration).toString();
      warnings.add(
        '${asset.name} is shorter than the template slot — clip trimmed',
      );
    }
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, dynamic>();
}
