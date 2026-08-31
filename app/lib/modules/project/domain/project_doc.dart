part of 'project.dart';

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
       captionTracks = [],
       references = [],
       trackers = [],
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
        'captionTracks',
        'references',
        'trackers',
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
    for (final t in (j['captionTracks'] as List<dynamic>? ?? const [])) {
      try {
        doc.captionTracks.add(
          CaptionTrack.fromJson(
            t as Map<String, dynamic>,
            onError: (what, error) => quarantine('caption $what', error),
          ),
        );
      } catch (e) {
        quarantine('caption track', e);
      }
    }
    for (final value in (j['references'] as List<dynamic>? ?? const [])) {
      try {
        doc.references.add(
          MediaReference.fromJson(value as Map<String, dynamic>),
        );
      } catch (e) {
        quarantine('media reference', e);
      }
    }
    for (final value in (j['trackers'] as List<dynamic>? ?? const [])) {
      // Tracker.fromJson returns null rather than throwing for anything the
      // engine loader would quarantine, so the two sides agree (TRK-16).
      final tracker = value is Map<String, dynamic>
          ? Tracker.fromJson(value)
          : null;
      if (tracker == null) {
        quarantine('tracker', 'malformed tracker dropped');
        continue;
      }
      doc.trackers.add(tracker);
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
    _repairCaptions(report);
    _repairTrackers(report);
  }

  /// Trackers must resolve to live media and a live clip, and lie inside that
  /// clip. A pin whose tracker did not survive is dropped, so no clip is left
  /// asking the compositor for a pose nothing can supply (**TRK-22**).
  void _repairTrackers(RepairReport? report) {
    final mediaIds = media.map((m) => m.id).toSet();
    final clipsById = {for (final c in clips) c.id: c};
    final seen = <String>{};
    trackers.removeWhere((tracker) {
      String? why;
      final clip = clipsById[tracker.sourceClipId];
      if (!seen.add(tracker.id)) {
        why = 'duplicate id';
      } else if (!mediaIds.contains(tracker.mediaId)) {
        why = 'unknown media';
      } else if (clip == null) {
        why = 'unknown clip';
      } else if (tracker.endTime > clip.duration) {
        why = 'range outside its clip';
      }
      if (why == null) return false;
      seen.remove(tracker.id);
      report?.issues.add('tracker ${tracker.id}: $why');
      return true;
    });

    final trackerIds = trackers.map((t) => t.id).toSet();
    for (final clip in clips) {
      final pin = TrackPin.fromExtra(clip.extra);
      if (!clip.extra.containsKey(kTrackPinKey)) continue;
      if (pin != null && trackerIds.contains(pin.trackerId)) continue;
      clip.extra.remove(kTrackPinKey);
      report?.issues.add('clip ${clip.label}: unpinned, tracker missing');
    }
  }

  /// Caption cues are ordered and non-overlapping. Every cue occupies at
  /// least one sequence frame. When a later cue overlaps an earlier one it is
  /// moved to the earlier cue's end; its duration and word offsets are kept.
  void _repairCaptions(RepairReport? report) {
    final trackIds = <String>{};
    captionTracks.removeWhere((track) {
      if (trackIds.add(track.id)) return false;
      report?.issues.add('caption track ${track.id}: duplicate id');
      return true;
    });
    for (final track in captionTracks) {
      track.items.sort((a, b) => a.start.compareTo(b.start));
      Rt? previousEnd;
      final itemIds = <String>{};
      track.items.removeWhere((item) {
        if (itemIds.add(item.id)) return false;
        report?.issues.add('caption ${item.id}: duplicate id');
        return true;
      });
      for (final item in track.items) {
        var shift = Rt.zero();
        if (item.start < Rt.zero()) {
          shift = Rt.zero().minus(item.start);
          item.start = Rt.zero();
          report?.issues.add('caption ${item.id}: negative start clamped');
        }
        if (previousEnd != null && item.start < previousEnd) {
          shift = shift.plus(previousEnd.minus(item.start));
          item.start = previousEnd;
          report?.issues.add('caption ${item.id}: overlap moved forward');
        }
        if (shift > Rt.zero()) {
          for (final word in item.words) {
            word.start = word.start.plus(shift);
            word.end = word.end.plus(shift);
          }
        }
        if (item.duration < frameDuration) {
          item.duration = frameDuration;
          report?.issues.add(
            'caption ${item.id}: duration raised to one frame',
          );
        }
        _repairCaptionWords(item, report);
        previousEnd = item.end;
      }
    }
  }

  void _repairCaptionWords(CaptionItem item, RepairReport? report) {
    item.words.sort((a, b) => a.start.compareTo(b.start));
    final wordIds = <String>{};
    item.words.removeWhere((word) {
      if (word.id == null || wordIds.add(word.id!)) return false;
      report?.issues.add('caption ${item.id} word ${word.id}: duplicate id');
      return true;
    });
    Rt? previousEnd;
    item.words.removeWhere((word) {
      var start = word.start.clampTo(item.start, item.end);
      final end = word.end.clampTo(item.start, item.end);
      if (previousEnd != null && start < previousEnd!) start = previousEnd!;
      if (end <= start) {
        report?.issues.add('caption ${item.id} word ${word.id}: invalid span');
        return true;
      }
      if (start != word.start || end != word.end) {
        report?.issues.add('caption ${item.id} word ${word.id}: span clamped');
      }
      word.start = start;
      word.end = end;
      if (word.confidence != null) {
        word.confidence = word.confidence!.clamp(0.0, 1.0);
      }
      previousEnd = end;
      return false;
    });
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
  final List<CaptionTrack> captionTracks;
  final List<MediaReference> references;

  /// Solved area-tracking paths (`data/area_track.dart`, **TRK-13**).
  final List<Tracker> trackers;

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

  Tracker? trackerById(String id) =>
      trackers.firstWhereOrNull((t) => t.id == id);

  /// Trackers solved against [clipId]'s region.
  List<Tracker> trackersForClip(String clipId) =>
      trackers.where((t) => t.sourceClipId == clipId).toList();
  MediaAsset? assetById(String id) => media.firstWhereOrNull((m) => m.id == id);
  CaptionTrack? captionTrackById(String id) =>
      captionTracks.firstWhereOrNull((t) => t.id == id);

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
    for (final track in captionTracks) {
      for (final item in track.items) {
        if (item.end > end) end = item.end;
      }
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
    if (captionTracks.isNotEmpty)
      'captionTracks': [for (final track in captionTracks) track.toJson()],
    if (references.isNotEmpty)
      'references': [for (final reference in references) reference.toJson()],
    if (trackers.isNotEmpty)
      'trackers': [for (final tracker in trackers) tracker.toJson()],
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
    for (final track in copy.captionTracks) {
      final json = track.toJson();
      json['id'] = generateId();
      final items = json['items'] as List<dynamic>;
      for (final item in items.cast<Map<String, dynamic>>()) {
        item['id'] = generateId();
        final words = item['words'] as List<dynamic>? ?? const [];
        for (final word in words.cast<Map<String, dynamic>>()) {
          if (word.containsKey('id')) word['id'] = generateId();
        }
      }
      clone.captionTracks.add(CaptionTrack.fromJson(json));
    }
    for (final reference in copy.references) {
      clone.references.add(
        MediaReference.fromJson(reference.toJson()..['id'] = generateId()),
      );
    }
    // Trackers are not carried into a duplicate: they reference the original's
    // clip ids, which the clone regenerates. Rather than rewrite the ids and
    // the pins that point at them, a duplicated project starts untracked
    // (called out in tracking.md's non-goals as templates are).
    return clone;
  }
}
