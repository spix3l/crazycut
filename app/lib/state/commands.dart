import 'dart:convert';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/caption.dart';
import 'package:crazycut_app/data/transition.dart';

/// A reversible document mutation (TIM-20). Commands own the *data* needed to
/// go back and forth; they never hold references to live entities, so undo
/// survives any number of intervening edits.
abstract class Command {
  String get label;

  void apply(ProjectDoc doc);
  void revert(ProjectDoc doc);

  /// Rough retained size, used by the stack's memory cap.
  int get sizeBytes;
}

/// Before/after JSON for one entity. A null side means "did not exist".
class EntityDelta {
  const EntityDelta(this.before, this.after);

  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  bool get isNoop {
    if (before == null && after == null) return true;
    if (before == null || after == null) return false;
    return jsonEncode(before) == jsonEncode(after);
  }

  int get sizeBytes =>
      (before == null ? 0 : jsonEncode(before).length) +
      (after == null ? 0 : jsonEncode(after).length);
}

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

/// Records what an operation touched, then turns it into a [DocumentEdit].
///
/// Callers mutate the document directly but declare each entity they are about
/// to change; the transaction snapshots the "before" side on first touch and
/// the "after" side at commit. One transaction stays open for the length of a
/// drag, which is where gesture coalescing (TIM-20) comes from.
class EditTransaction {
  EditTransaction(this.doc, this.label);

  final ProjectDoc doc;
  String label;

  final Map<String, Map<String, dynamic>?> _clips = {};
  final Map<String, Map<String, dynamic>?> _tracks = {};
  final Map<String, Map<String, dynamic>?> _markers = {};
  final Map<String, Map<String, dynamic>?> _transitions = {};
  final Map<String, Map<String, dynamic>?> _captionTracks = {};
  String? _nameBefore;
  Map<String, dynamic>? _settingsBefore;

  void clip(String id) =>
      _clips.putIfAbsent(id, () => _deepCopyJson(doc.clipById(id)?.toJson()));

  /// `Clip.toJson` hands out the live [Clip.effects] list; a shallow copy
  /// would alias it and make every effect edit look like a no-op. Copies the
  /// nested maps/lists so snapshots are frozen at touch time. Map keys keep
  /// their runtime type (fromJson casts to `Map<String, dynamic>`).
  static Map<String, dynamic>? _deepCopyJson(Map<String, dynamic>? json) {
    if (json == null) return null;

    dynamic copyValue(dynamic value) {
      if (value is Map<String, dynamic>) {
        return {for (final e in value.entries) e.key: copyValue(e.value)};
      }
      if (value is Map) {
        return {for (final e in value.entries) e.key: copyValue(e.value)};
      }
      if (value is List) return [for (final e in value) copyValue(e)];
      return value;
    }

    return copyValue(json) as Map<String, dynamic>;
  }

  void clips(Iterable<String> ids) => ids.forEach(clip);

  void track(String id) =>
      _tracks.putIfAbsent(id, () => doc.trackById(id)?.toJson());

  void tracks(Iterable<String> ids) => ids.forEach(track);

  void marker(String id) => _markers.putIfAbsent(id, () => _markerJson(id));

  Map<String, dynamic>? _markerJson(String id) {
    for (final m in doc.markers) {
      if (m.id == id) return m.toJson();
    }
    return null;
  }

  void transition(String id) =>
      _transitions.putIfAbsent(id, () => doc.transitionById(id)?.toJson());

  /// Snapshots a whole caption track. Text, timing and style mutations can
  /// therefore be committed as one command without retaining live objects.
  void captionTrack(String id) => _captionTracks.putIfAbsent(
    id,
    () => _deepCopyJson(doc.captionTrackById(id)?.toJson()),
  );

  /// The "before" JSON snapshotted for [id], or null when untouched/absent.
  /// Sanitize passes read these to see the pre-op geometry of a clip without
  /// holding live references.
  Map<String, dynamic>? clipSnapshot(String id) => _clips[id];

  Map<String, dynamic>? transitionSnapshot(String id) => _transitions[id];

  bool touchedClip(String id) => _clips.containsKey(id);

  void name() => _nameBefore ??= doc.name;

  void settings() => _settingsBefore ??= doc.settings.toJson();

  /// Every clip on the given tracks, for ripple-style operations.
  void wholeTracks(Iterable<String> trackIds) {
    for (final id in trackIds) {
      clips(doc.clipsOn(id).map((c) => c.id));
    }
  }

  DocumentEdit? build() {
    final edit = DocumentEdit(
      label: label,
      clips: {
        for (final entry in _clips.entries)
          entry.key: EntityDelta(
            entry.value,
            doc.clipById(entry.key)?.toJson(),
          ),
      },
      tracks: {
        for (final entry in _tracks.entries)
          entry.key: EntityDelta(
            entry.value,
            doc.trackById(entry.key)?.toJson(),
          ),
      },
      markers: {
        for (final entry in _markers.entries)
          entry.key: EntityDelta(entry.value, _markerJson(entry.key)),
      },
      transitions: {
        for (final entry in _transitions.entries)
          entry.key: EntityDelta(
            entry.value,
            doc.transitionById(entry.key)?.toJson(),
          ),
      },
      captionTracks: {
        for (final entry in _captionTracks.entries)
          entry.key: EntityDelta(
            entry.value,
            _deepCopyJson(doc.captionTrackById(entry.key)?.toJson()),
          ),
      },
      nameBefore: _nameBefore,
      nameAfter: _nameBefore == null ? null : doc.name,
      settingsBefore: _settingsBefore,
      settingsAfter: _settingsBefore == null ? null : doc.settings.toJson(),
    );
    return edit.isNoop ? null : edit;
  }
}

/// Undo/redo history with a memory budget (TIM-20: unlimited depth, capped
/// around 100 MB, oldest dropped first).
class CommandStack {
  CommandStack({this.memoryBudgetBytes = 100 * 1024 * 1024});

  final int memoryBudgetBytes;
  final List<Command> _undo = [];
  final List<Command> _redo = [];
  int _bytes = 0;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get depth => _undo.length;
  int get bytes => _bytes;

  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  /// Pushes an already-applied command. Redo is dropped, per TIM-21.
  void push(Command command) {
    _undo.add(command);
    _bytes += command.sizeBytes;
    _redo.clear();
    while (_bytes > memoryBudgetBytes && _undo.length > 1) {
      _bytes -= _undo.removeAt(0).sizeBytes;
    }
  }

  Command? undo(ProjectDoc doc) {
    if (_undo.isEmpty) return null;
    final command = _undo.removeLast();
    _bytes -= command.sizeBytes;
    command.revert(doc);
    _redo.add(command);
    return command;
  }

  Command? redo(ProjectDoc doc) {
    if (_redo.isEmpty) return null;
    final command = _redo.removeLast();
    command.apply(doc);
    _undo.add(command);
    _bytes += command.sizeBytes;
    return command;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
    _bytes = 0;
  }
}
