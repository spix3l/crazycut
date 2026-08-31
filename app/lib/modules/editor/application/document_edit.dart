part of 'commands.dart';

/// The one concrete command type: a set of entity deltas plus optional
/// document-level fields. Everything the editor does — move, trim, split,
/// delete, paste, retrack, rename — is expressible as this, which keeps
/// apply/revert symmetric instead of hand-written per operation.
class DocumentEdit implements Command {
  DocumentEdit({
    required this.label,
    this.clips = const {},
    this.tracks = const {},
    this.markers = const {},
    this.transitions = const {},
    this.captionTracks = const {},
    this.trackers = const {},
    this.nameBefore,
    this.nameAfter,
    this.settingsBefore,
    this.settingsAfter,
  });

  @override
  final String label;

  final Map<String, EntityDelta> clips;
  final Map<String, EntityDelta> tracks;
  final Map<String, EntityDelta> markers;

  /// Transition deltas so transition ops undo in ONE step (TRA-2/4/6).
  final Map<String, EntityDelta> transitions;
  final Map<String, EntityDelta> captionTracks;

  /// Tracker deltas, so installing or re-solving a path is ONE undo step
  /// (**TRK-15**). Snapshotting the entity rather than the whole document is
  /// what keeps that inside the 50 ms commit budget even for a dense path.
  final Map<String, EntityDelta> trackers;

  final String? nameBefore;
  final String? nameAfter;
  final Map<String, dynamic>? settingsBefore;
  final Map<String, dynamic>? settingsAfter;

  bool get isNoop =>
      clips.values.every((d) => d.isNoop) &&
      tracks.values.every((d) => d.isNoop) &&
      markers.values.every((d) => d.isNoop) &&
      transitions.values.every((d) => d.isNoop) &&
      captionTracks.values.every((d) => d.isNoop) &&
      trackers.values.every((d) => d.isNoop) &&
      nameBefore == nameAfter &&
      (settingsBefore == null ||
          jsonEncode(settingsBefore) == jsonEncode(settingsAfter));

  @override
  int get sizeBytes {
    var total = 64;
    for (final d in clips.values) {
      total += d.sizeBytes;
    }
    for (final d in tracks.values) {
      total += d.sizeBytes;
    }
    for (final d in markers.values) {
      total += d.sizeBytes;
    }
    for (final d in transitions.values) {
      total += d.sizeBytes;
    }
    for (final d in captionTracks.values) {
      total += d.sizeBytes;
    }
    for (final d in trackers.values) {
      total += d.sizeBytes;
    }
    return total;
  }

  @override
  void apply(ProjectDoc doc) => _write(doc, forward: true);

  @override
  void revert(ProjectDoc doc) => _write(doc, forward: false);

  void _write(ProjectDoc doc, {required bool forward}) {
    Map<String, dynamic>? side(EntityDelta d) => forward ? d.after : d.before;

    // Removals first, so a track can be deleted and re-added in one edit.
    clips.forEach((id, delta) {
      if (side(delta) == null) doc.clips.removeWhere((c) => c.id == id);
    });
    tracks.forEach((id, delta) {
      if (side(delta) == null) doc.tracks.removeWhere((t) => t.id == id);
    });
    markers.forEach((id, delta) {
      if (side(delta) == null) doc.markers.removeWhere((m) => m.id == id);
    });
    transitions.forEach((id, delta) {
      if (side(delta) == null) doc.transitions.removeWhere((t) => t.id == id);
    });
    captionTracks.forEach((id, delta) {
      if (side(delta) == null) {
        doc.captionTracks.removeWhere((t) => t.id == id);
      }
    });
    trackers.forEach((id, delta) {
      if (side(delta) == null) doc.trackers.removeWhere((t) => t.id == id);
    });

    tracks.forEach((id, delta) {
      final json = side(delta);
      if (json == null) return;
      final track = Track.fromJson(json);
      final at = doc.tracks.indexWhere((t) => t.id == id);
      if (at >= 0) {
        doc.tracks[at] = track;
      } else {
        doc.tracks.add(track);
      }
    });
    clips.forEach((id, delta) {
      final json = side(delta);
      if (json == null) return;
      final clip = Clip.fromJson(json);
      final at = doc.clips.indexWhere((c) => c.id == id);
      if (at >= 0) {
        doc.clips[at] = clip;
      } else {
        doc.clips.add(clip);
      }
    });
    transitions.forEach((id, delta) {
      final json = side(delta);
      if (json == null) return;
      final transition = Transition.fromJson(json);
      final at = doc.transitions.indexWhere((t) => t.id == id);
      if (at >= 0) {
        doc.transitions[at] = transition;
      } else {
        doc.transitions.add(transition);
      }
    });
    captionTracks.forEach((id, delta) {
      final json = side(delta);
      if (json == null) return;
      final track = CaptionTrack.fromJson(json);
      final at = doc.captionTracks.indexWhere((t) => t.id == id);
      if (at >= 0) {
        doc.captionTracks[at] = track;
      } else {
        doc.captionTracks.add(track);
      }
    });

    trackers.forEach((id, delta) {
      final json = side(delta);
      if (json == null) return;
      final tracker = Tracker.fromJson(json);
      if (tracker == null) return;
      final at = doc.trackers.indexWhere((t) => t.id == id);
      if (at >= 0) {
        doc.trackers[at] = tracker;
      } else {
        doc.trackers.add(tracker);
      }
    });

    final name = forward ? nameAfter : nameBefore;
    if (name != null) doc.name = name;
    final settings = forward ? settingsAfter : settingsBefore;
    if (settings != null) {
      final parsed = SequenceSettings.fromJson(settings);
      doc.settings
        ..width = parsed.width
        ..height = parsed.height
        ..fps = parsed.fps
        ..audioSampleRate = parsed.audioSampleRate
        ..background = parsed.background
        ..master = parsed.master;
    }
  }
}
