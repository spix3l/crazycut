import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';

/// Document mutations for the timeline (TIM-3/4/6/9/10/11/15/16/20/21).
///
/// Every edit goes through here so undo stays honest: there are no
/// side-channel writes to [doc] anywhere else in the app. Snapshots are
/// captured before a mutation; continuous gestures (drag, trim) wrap
/// themselves in [beginGesture] / [endGesture] so they commit exactly one
/// undo entry on release.
mixin TimelineEdits on ChangeNotifier {
  ProjectDoc get doc;
  Rt get playhead;
  double get fps;

  /// Persist + push the new graph to the engine.
  void markDirty();

  String? selectedClipId;

  /// Seconds of the snap candidate the last move/trim locked onto, for the
  /// indicator line. Null when nothing snapped.
  double? snapIndicator;

  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  static const int _maxUndo = 100;
  bool _inGesture = false;

  /// True between [beginGesture] and [endGesture].
  bool get inGesture => _inGesture;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// One frame at the sequence rate — the minimum clip length (TIM edge case).
  Rt get frameDuration => Rt.fromMicros((1000000 / (fps <= 0 ? 30 : fps)).round());

  // --- Undo -----------------------------------------------------------------

  void pushUndo() {
    if (_inGesture) return;
    _undoStack.add(doc.encode());
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  /// Opens a coalescing window: the whole drag lands as one undo step.
  void beginGesture() {
    if (_inGesture) return;
    pushUndo();
    _inGesture = true;
  }

  void endGesture() {
    if (!_inGesture) return;
    _inGesture = false;
    snapIndicator = null;
    markDirty();
    notifyListeners();
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(doc.encode());
    _restore(_undoStack.removeLast());
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(doc.encode());
    _restore(_redoStack.removeLast());
  }

  void _restore(String json) {
    final restored = ProjectDoc.decode(json);
    doc.media
      ..clear()
      ..addAll(restored.media);
    doc.tracks
      ..clear()
      ..addAll(restored.tracks);
    doc.clips
      ..clear()
      ..addAll(restored.clips);
    doc.markers
      ..clear()
      ..addAll(restored.markers);
    doc.name = restored.name;
    if (!doc.clips.any((c) => c.id == selectedClipId)) selectedClipId = null;
    markDirty();
    notifyListeners();
  }

  // --- Lookups --------------------------------------------------------------

  Clip? clipById(String? id) =>
      id == null ? null : doc.clips.firstWhereOrNull((c) => c.id == id);

  Clip? get selectedClip => clipById(selectedClipId);

  Track? trackById(String id) => doc.tracks.firstWhereOrNull((t) => t.id == id);

  List<Clip> clipsOn(String trackId) =>
      doc.clips.where((c) => c.trackId == trackId).toList()
        ..sort((a, b) => a.start.compareTo(b.start));

  /// Available media past the clip's out point, i.e. how far the tail can be
  /// pulled. Unknown asset duration (still probing) means "no limit".
  Rt? _sourceLimit(Clip clip) {
    final asset = doc.assetById(clip.mediaId);
    if (asset == null || asset.duration.isZero) return null;
    return asset.duration;
  }

  // --- Snapping (TIM-15) ----------------------------------------------------

  /// Snap candidates: sequence start, playhead, markers and every other clip
  /// edge. [pxPerSec] keeps the tolerance a constant ~8 px on screen at any
  /// zoom, so snapping feels the same when zoomed right in.
  Rt snapTime(Rt t, {String? excludeId, double pxPerSec = 40, bool enabled = true}) {
    snapIndicator = null;
    if (!enabled) return t;
    final tolerance = Rt.fromSeconds(8 / (pxPerSec <= 0 ? 40 : pxPerSec));
    var best = t;
    var bestDist = tolerance.micros + 1;
    void consider(Rt candidate) {
      final d = candidate.minus(t).micros.abs();
      if (d <= tolerance.micros && d < bestDist) {
        bestDist = d;
        best = candidate;
      }
    }

    consider(Rt.zero());
    consider(playhead);
    for (final m in doc.markers) {
      consider(m.time);
    }
    for (final c in doc.clips) {
      if (c.id == excludeId) continue;
      consider(c.start);
      consider(c.start.plus(c.duration));
    }
    if (best != t) snapIndicator = best.seconds;
    return best;
  }

  // --- Selection ------------------------------------------------------------

  void selectClip(String? id) {
    if (selectedClipId == id) return;
    selectedClipId = id;
    notifyListeners();
  }

  // --- Move (TIM-3/4) -------------------------------------------------------

  /// Moves a clip to [start] on [trackId]. Same-kind tracks only; overlapping
  /// neighbours are pushed right rather than being overwritten.
  void moveClip(
    String id, {
    String? trackId,
    required Rt start,
    bool snap = true,
    double pxPerSec = 40,
  }) {
    final clip = clipById(id);
    if (clip == null) return;
    final target = trackById(trackId ?? clip.trackId);
    final source = trackById(clip.trackId);
    if (target == null || source == null || target.kind != source.kind) return;
    if (target.lock || source.lock) return;

    var newStart = snapTime(start, excludeId: id, pxPerSec: pxPerSec, enabled: snap);
    if (newStart < Rt.zero()) newStart = Rt.zero();
    if (clip.trackId == target.id && clip.start == newStart) return;

    pushUndo();
    clip.trackId = target.id;
    clip.start = newStart;
    _pushAside(clip);
    markDirty();
    notifyListeners();
  }

  /// Keeps a track free of overlaps by sliding everything that collides with
  /// [anchor] to the right, cascading down the lane (TIM-4, "push right").
  void _pushAside(Clip anchor) {
    var frontier = anchor.start.plus(anchor.duration);
    for (final c in clipsOn(anchor.trackId)) {
      if (c.id == anchor.id) continue;
      if (c.start.plus(c.duration) <= anchor.start) continue;
      if (c.start < frontier) c.start = frontier;
      frontier = c.start.plus(c.duration);
    }
  }

  // --- Trim (TIM-6 edge trim / TIM-7 handle limits) -------------------------

  /// Drags the head. The clip's source in-point follows, so the picture under
  /// the remaining span does not shift.
  void trimStart(String id, Rt newStart, {bool snap = true, double pxPerSec = 40}) {
    final clip = clipById(id);
    if (clip == null || (trackById(clip.trackId)?.lock ?? false)) return;
    final target = snapTime(newStart, excludeId: id, pxPerSec: pxPerSec, enabled: snap);
    var delta = target.minus(clip.start);
    if (delta < Rt.zero()) {
      // Pulling the head left spends source handle, and can never cross 0.
      if (Rt.zero().minus(delta) > clip.sourceIn) delta = Rt.zero().minus(clip.sourceIn);
      if (clip.start.plus(delta) < Rt.zero()) delta = Rt.zero().minus(clip.start);
    } else {
      // Pushing it right can never collapse the clip below one frame.
      final maxDelta = clip.duration.minus(frameDuration);
      if (delta > maxDelta) delta = maxDelta;
    }
    if (delta.isZero) return;

    pushUndo();
    clip.start = clip.start.plus(delta);
    clip.sourceIn = clip.sourceIn.plus(delta);
    clip.duration = clip.duration.minus(delta);
    markDirty();
    notifyListeners();
  }

  /// Drags the tail. Stops at the end of the source media when known.
  void trimEnd(String id, Rt newEnd, {bool snap = true, double pxPerSec = 40}) {
    final clip = clipById(id);
    if (clip == null || (trackById(clip.trackId)?.lock ?? false)) return;
    final target = snapTime(newEnd, excludeId: id, pxPerSec: pxPerSec, enabled: snap);
    var duration = target.minus(clip.start);
    if (duration < frameDuration) duration = frameDuration;
    final limit = _sourceLimit(clip);
    if (limit != null) {
      final available = limit.minus(clip.sourceIn);
      if (duration > available) duration = available;
    }
    if (duration == clip.duration || duration <= Rt.zero()) return;

    pushUndo();
    clip.duration = duration;
    _pushAside(clip);
    markDirty();
    notifyListeners();
  }

  // --- Split (TIM-10) -------------------------------------------------------

  /// Splits [clip] at [t]; returns the id of the new right-hand clip.
  String? splitClip(Clip clip, Rt t) {
    final head = t.minus(clip.start);
    if (head < frameDuration || clip.duration.minus(head) < frameDuration) return null;
    pushUndo();
    final right = Clip(
      id: generateId(),
      trackId: clip.trackId,
      mediaId: clip.mediaId,
      label: clip.label,
      start: t,
      duration: clip.duration.minus(head),
      sourceIn: clip.sourceIn.plus(head),
      speed: clip.speed,
    );
    clip.duration = head;
    doc.clips.add(right);
    markDirty();
    notifyListeners();
    return right.id;
  }

  /// Splits the selection, or every clip under the playhead when nothing is
  /// selected.
  List<String> splitAtPlayhead() {
    final under = doc.clips
        .where((c) => playhead > c.start && playhead < c.start.plus(c.duration))
        .toList();
    if (under.isEmpty) return const [];
    final targets = under.any((c) => c.id == selectedClipId)
        ? under.where((c) => c.id == selectedClipId).toList()
        : under;
    final created = <String>[];
    for (final clip in targets) {
      final id = splitClip(clip, playhead);
      if (id != null) created.add(id);
    }
    return created;
  }

  // --- Delete (TIM-9) -------------------------------------------------------

  void deleteClip(String id, {bool ripple = false}) {
    final clip = clipById(id);
    if (clip == null || (trackById(clip.trackId)?.lock ?? false)) return;
    pushUndo();
    final trackId = clip.trackId;
    final gapStart = clip.start;
    final gap = clip.duration;
    doc.clips.remove(clip);
    if (ripple) {
      for (final c in clipsOn(trackId)) {
        if (c.start >= gapStart) c.start = c.start.minus(gap);
      }
    }
    if (selectedClipId == id) selectedClipId = null;
    markDirty();
    notifyListeners();
  }

  void deleteSelected({bool ripple = false}) {
    final id = selectedClipId;
    if (id != null) deleteClip(id, ripple: ripple);
  }

  // --- Tracks (TIM-1) -------------------------------------------------------

  Track addTrack(String kind) {
    pushUndo();
    final peers = doc.tracks.where((t) => t.kind == kind).toList();
    final track = Track(
      id: generateId(),
      kind: kind,
      name: '${kind == 'video' ? 'V' : 'A'}${peers.length + 1}',
      index: peers.length,
    );
    doc.tracks.add(track);
    markDirty();
    notifyListeners();
    return track;
  }

  // --- Markers (TIM-11) -----------------------------------------------------

  Marker addMarker({String name = ''}) {
    pushUndo();
    final marker = Marker(id: generateId(), time: playhead, name: name);
    doc.markers.add(marker);
    markDirty();
    notifyListeners();
    return marker;
  }

  void removeMarker(String id) {
    final marker = doc.markers.firstWhereOrNull((m) => m.id == id);
    if (marker == null) return;
    pushUndo();
    doc.markers.remove(marker);
    markDirty();
    notifyListeners();
  }

  /// Nearest cut point after/before [from] — backs PageUp/PageDown and
  /// Shift+arrow marker jumps (TIM-12).
  Rt? nextEdge(Rt from, {bool forward = true}) {
    final edges = <Rt>[Rt.zero()];
    for (final c in doc.clips) {
      edges.add(c.start);
      edges.add(c.start.plus(c.duration));
    }
    for (final m in doc.markers) {
      edges.add(m.time);
    }
    edges.sort();
    if (forward) return edges.firstWhereOrNull((e) => e > from);
    return edges.lastWhereOrNull((e) => e < from);
  }
}
