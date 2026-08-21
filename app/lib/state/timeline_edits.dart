import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/commands.dart';

/// Which continuous edit a drag is performing (TIM-3/6).
enum EditGesture { move, trimStart, trimEnd, roll, slip, slide }

/// How a pool asset lands on the timeline (TIM-5).
enum DropMode { overwrite, insert, append }

/// Snapshot of a clip's timing at the start of a gesture, so every update
/// during the drag is computed from the origin rather than from the last
/// frame's result (no drift, no double-snapping).
class ClipTiming {
  ClipTiming(this.trackId, this.start, this.duration, this.sourceIn);

  factory ClipTiming.of(Clip c) => ClipTiming(c.trackId, c.start, c.duration, c.sourceIn);

  final String trackId;
  final Rt start;
  final Rt duration;
  final Rt sourceIn;

  Rt get end => start.plus(duration);
}

class _Gesture {
  _Gesture(this.kind, this.primaryId, this.origins, this.trackOrder, {this.breakLinks = false});

  final EditGesture kind;
  final String primaryId;
  final Map<String, ClipTiming> origins;
  final List<String> trackOrder;
  final bool breakLinks;
}

/// Every document mutation in the editor (TIM-1..18, 20/21).
///
/// The mixin owns the command history, the selection and the clipboard; hosts
/// provide the document, the playhead and the persistence hook. Operations
/// mutate [doc] inside an [EditTransaction] so undo is derived from what
/// actually changed rather than hand-maintained per operation.
mixin TimelineEdits on ChangeNotifier {
  ProjectDoc get doc;
  Rt get playhead;
  double get fps;

  /// Persist + push the new graph to the engine.
  void markDirty();

  final CommandStack history = CommandStack();

  /// Selected clip ids (TIM-16). Order is irrelevant; [selectedClipId] is the
  /// one the inspector binds to.
  final Set<String> selection = {};

  /// Playback/export range (TIM-12).
  Rt? inPoint;
  Rt? outPoint;

  /// TIM-9 global magnetic mode: deletes close the gap by default.
  bool magnetic = false;

  /// Seconds of the snap candidate the current drag locked onto (TIM-15).
  double? snapIndicator;

  /// Human-readable delta for the trim tooltip, e.g. "+12 f" (TIM-7).
  String? trimFeedback;

  /// True when a trim is being held against a media handle or a neighbour.
  bool trimAtLimit = false;

  final List<Map<String, dynamic>> _clipboard = [];
  Rt _clipboardOrigin = Rt.zero();

  EditTransaction? _openTx;
  _Gesture? _gesture;

  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;
  bool get inGesture => _openTx != null;
  bool get hasClipboard => _clipboard.isNotEmpty;

  String? get selectedClipId => selection.isEmpty ? null : selection.first;
  Clip? get selectedClip => selection.isEmpty ? null : doc.clipById(selection.first);
  List<Clip> get selectedClips =>
      selection.map(doc.clipById).whereType<Clip>().toList();

  /// One frame of sequence time — the minimum clip length.
  Rt get frameDuration => doc.frameDuration;

  /// Rounds a time to the sequence's frame grid using exact rational maths, so
  /// edits at 29.97 (30000/1001) land on real frame boundaries rather than
  /// drifting by fractions of a frame (TIM acceptance criterion 2).
  Rt quantiseToFrame(Rt t) {
    final frame = frameDuration;
    if (frame.isZero || frame.num == 0) return t;
    final ratio = (t.num * frame.den) / (t.den * frame.num);
    return Rt(frame.num * ratio.round(), frame.den);
  }

  // --- Transactions ---------------------------------------------------------

  T _run<T>(String label, T Function(EditTransaction tx) body) {
    final open = _openTx;
    final tx = open ?? EditTransaction(doc, label);
    final result = body(tx);
    if (open == null) {
      _commit(tx);
    } else {
      markDirty();
      notifyListeners();
    }
    return result;
  }

  void _commit(EditTransaction tx) {
    final edit = tx.build();
    if (edit != null) {
      history.push(edit);
      markDirty();
    }
    notifyListeners();
  }

  /// Opens a coalescing window; everything until [endGesture] lands as one
  /// undo step (TIM-20).
  void beginGesture([String label = 'Edit']) {
    _openTx ??= EditTransaction(doc, label);
  }

  void endGesture() {
    final tx = _openTx;
    _openTx = null;
    _gesture = null;
    snapIndicator = null;
    trimFeedback = null;
    trimAtLimit = false;
    if (tx != null) _commit(tx);
  }

  void undo() {
    final command = history.undo(doc);
    if (command == null) return;
    _afterHistory();
  }

  void redo() {
    final command = history.redo(doc);
    if (command == null) return;
    _afterHistory();
  }

  void _afterHistory() {
    selection.removeWhere((id) => doc.clipById(id) == null);
    markDirty();
    notifyListeners();
  }

  // --- Lookups --------------------------------------------------------------

  Clip? clipById(String? id) => id == null ? null : doc.clipById(id);
  Track? trackById(String? id) => id == null ? null : doc.trackById(id);
  List<Clip> clipsOn(String trackId) => doc.clipsOn(trackId);

  /// Lanes top-to-bottom: video descending (V2 above V1), then audio.
  List<Track> get laneOrder => [
        ...doc.videoTracks.reversed,
        ...doc.audioTracks,
      ];

  bool _locked(String trackId) => trackById(trackId)?.lock ?? false;

  /// Total source available to a clip, or null when the media is unknown
  /// (still probing, offline, or a still image).
  Rt? _sourceLimit(Clip clip) {
    final asset = doc.assetById(clip.mediaId);
    if (asset == null || asset.duration.isZero) return null;
    return asset.duration;
  }

  /// Longest the clip can be given its in-point and speed.
  Rt? _maxDuration(Clip clip, {Rt? sourceIn}) {
    final limit = _sourceLimit(clip);
    if (limit == null) return null;
    final available = limit.minus(sourceIn ?? clip.sourceIn);
    final speed = clip.speedValue <= 0 ? 1.0 : clip.speedValue;
    return Rt.fromMicros((available.micros / speed).round());
  }

  // --- Selection (TIM-16/18) ------------------------------------------------

  void selectClip(String? id, {bool additive = false, bool withLinked = true}) {
    if (id == null) {
      if (selection.isEmpty) return;
      selection.clear();
      notifyListeners();
      return;
    }
    final clip = doc.clipById(id);
    if (clip == null) return;
    final ids = withLinked ? doc.linkedWith(clip).map((c) => c.id) : [id];
    if (additive) {
      if (selection.contains(id)) {
        selection.removeAll(ids);
      } else {
        selection.addAll(ids);
      }
    } else {
      selection
        ..clear()
        ..addAll(ids);
    }
    notifyListeners();
  }

  void selectAll() {
    selection
      ..clear()
      ..addAll(doc.clips.map((c) => c.id));
    notifyListeners();
  }

  void invertSelection() {
    final inverted = doc.clips.map((c) => c.id).toSet()..removeAll(selection);
    selection
      ..clear()
      ..addAll(inverted);
    notifyListeners();
  }

  /// Track-header click selects that track's clips (TIM-16).
  void selectTrack(String trackId, {bool additive = false}) {
    final ids = doc.clipsOn(trackId).map((c) => c.id);
    if (!additive) selection.clear();
    selection.addAll(ids);
    notifyListeners();
  }

  /// Marquee result: everything intersecting the time span on those tracks.
  void selectRange({
    required Iterable<String> trackIds,
    required Rt from,
    required Rt to,
    bool additive = false,
  }) {
    final lo = from <= to ? from : to;
    final hi = from <= to ? to : from;
    final tracks = trackIds.toSet();
    final hits = doc.clips
        .where((c) => tracks.contains(c.trackId) && c.start < hi && c.end > lo)
        .map((c) => c.id);
    if (!additive) selection.clear();
    selection.addAll(hits);
    notifyListeners();
  }

  // --- Snapping (TIM-15) ----------------------------------------------------

  /// Snap candidates: sequence start/end, playhead, in/out points, markers and
  /// every clip edge not being dragged. Tolerance is a constant ~8 px at any
  /// zoom, so snapping feels identical zoomed in or out.
  Rt snapTime(
    Rt t, {
    Set<String> exclude = const {},
    double pxPerSec = 40,
    bool enabled = true,
  }) {
    snapIndicator = null;
    final target = quantiseToFrame(t);
    if (!enabled) return target;
    t = target;
    final tolerance = Rt.fromSeconds(8 / (pxPerSec <= 0 ? 40 : pxPerSec));
    var best = t;
    var bestDist = tolerance.micros + 1;
    void consider(Rt? candidate) {
      if (candidate == null) return;
      final d = candidate.minus(t).micros.abs();
      if (d <= tolerance.micros && d < bestDist) {
        bestDist = d;
        best = candidate;
      }
    }

    consider(Rt.zero());
    consider(playhead);
    consider(inPoint);
    consider(outPoint);
    consider(doc.sequenceDuration);
    for (final m in doc.markers) {
      consider(m.time);
    }
    for (final c in doc.clips) {
      if (exclude.contains(c.id)) continue;
      consider(c.start);
      consider(c.end);
    }
    if (best != t) snapIndicator = best.seconds;
    return best;
  }

  /// Snaps a delta by testing both edges of the dragged span (TIM-15).
  Rt _snapDelta(
    Rt delta, {
    required Rt spanStart,
    required Rt spanEnd,
    required Set<String> exclude,
    required double pxPerSec,
    required bool enabled,
  }) {
    delta = quantiseToFrame(delta);
    if (!enabled) {
      snapIndicator = null;
      return delta;
    }
    final startSnap = snapTime(spanStart.plus(delta),
        exclude: exclude, pxPerSec: pxPerSec, enabled: true);
    final startIndicator = snapIndicator;
    final startShift = startSnap.minus(spanStart.plus(delta));
    final endSnap = snapTime(spanEnd.plus(delta),
        exclude: exclude, pxPerSec: pxPerSec, enabled: true);
    final endIndicator = snapIndicator;
    final endShift = endSnap.minus(spanEnd.plus(delta));

    if (startShift.isZero && endShift.isZero) {
      snapIndicator = null;
      return delta;
    }
    if (endShift.isZero || (!startShift.isZero &&
        startShift.micros.abs() <= endShift.micros.abs())) {
      snapIndicator = startIndicator;
      return delta.plus(startShift);
    }
    snapIndicator = endIndicator;
    return delta.plus(endShift);
  }

  // --- Overlap policy (TIM-4) ----------------------------------------------

  /// Slides everything colliding with [anchor] to the right, cascading down
  /// the lane. Manual drags can never create an overlap.
  void _pushAside(EditTransaction tx, Clip anchor) {
    var frontier = anchor.end;
    for (final c in doc.clipsOn(anchor.trackId)) {
      if (c.id == anchor.id) continue;
      if (c.end <= anchor.start) continue;
      if (c.start < frontier) {
        tx.clip(c.id);
        c.start = frontier;
      }
      frontier = c.end;
    }
  }

  /// Clears [from, to) on a track by trimming, splitting or removing whatever
  /// sits there — the overwrite drop mode and overwrite paste.
  void _clearRange(EditTransaction tx, String trackId, Rt from, Rt to,
      {Set<String> except = const {}}) {
    for (final c in doc.clipsOn(trackId).toList()) {
      if (except.contains(c.id)) continue;
      if (c.end <= from || c.start >= to) continue;
      tx.clip(c.id);
      if (c.start >= from && c.end <= to) {
        doc.clips.remove(c);
        selection.remove(c.id);
        continue;
      }
      if (c.start < from && c.end > to) {
        // The new clip lands inside an existing one: keep the head, add a tail.
        final tailStart = to;
        final tail = c.cloneWithNewId(start: tailStart, linkedGroup: c.linkedGroup);
        tail.sourceIn = c.sourceIn.plus(tailStart.minus(c.start));
        tail.duration = c.end.minus(tailStart);
        c.duration = from.minus(c.start);
        doc.clips.add(tail);
        tx.clip(tail.id);
        continue;
      }
      if (c.start < from) {
        c.duration = from.minus(c.start);
      } else {
        final shift = to.minus(c.start);
        c.start = to;
        c.sourceIn = c.sourceIn.plus(shift);
        c.duration = c.duration.minus(shift);
      }
    }
  }

  // --- Drag gestures --------------------------------------------------------

  /// Captures origins for a drag. [primaryId] is the clip under the cursor;
  /// the whole selection (plus linked partners) moves with it unless
  /// [breakLinks] is set (Alt-drag, TIM-3).
  void beginDrag(EditGesture kind, String primaryId, {bool breakLinks = false}) {
    final primary = doc.clipById(primaryId);
    if (primary == null) return;
    if (!selection.contains(primaryId)) {
      selectClip(primaryId, withLinked: !breakLinks);
    }
    final ids = <String>{primaryId, ...selection};
    if (!breakLinks) {
      for (final id in ids.toList()) {
        final clip = doc.clipById(id);
        if (clip != null) ids.addAll(doc.linkedWith(clip).map((c) => c.id));
      }
    }
    final movable = ids.where((id) {
      final clip = doc.clipById(id);
      return clip != null && !_locked(clip.trackId);
    });
    beginGesture(switch (kind) {
      EditGesture.move => 'Move clips',
      EditGesture.trimStart || EditGesture.trimEnd => 'Trim clip',
      EditGesture.roll => 'Roll edit',
      EditGesture.slip => 'Slip clip',
      EditGesture.slide => 'Slide clip',
    });
    _gesture = _Gesture(
      kind,
      primaryId,
      {
        for (final id in movable) id: ClipTiming.of(doc.clipById(id)!),
      },
      laneOrder.map((t) => t.id).toList(),
      breakLinks: breakLinks,
    );
  }

  /// Starts a roll at the cut between two adjacent clips on one track: the
  /// pair's outer edges stay put while the cut moves (TIM-6).
  void beginRoll(String leftId, String rightId) {
    final left = doc.clipById(leftId);
    final right = doc.clipById(rightId);
    if (left == null || right == null) return;
    if (_locked(left.trackId) || _locked(right.trackId)) return;
    beginGesture('Roll edit');
    _gesture = _Gesture(
      EditGesture.roll,
      leftId,
      {leftId: ClipTiming.of(left), rightId: ClipTiming.of(right)},
      laneOrder.map((t) => t.id).toList(),
    );
  }

  /// Applies a drag. [deltaSeconds] is measured from the gesture origin;
  /// [laneDelta] is how many lanes the pointer crossed.
  void updateDrag(
    double deltaSeconds, {
    int laneDelta = 0,
    bool snap = true,
    double pxPerSec = 40,
  }) {
    final gesture = _gesture;
    if (gesture == null || gesture.origins.isEmpty) return;
    final delta = Rt.fromSeconds(deltaSeconds);
    switch (gesture.kind) {
      case EditGesture.move:
        _applyMove(gesture, delta, laneDelta, snap, pxPerSec);
      case EditGesture.trimStart:
        _applyTrim(gesture, delta, snap, pxPerSec, head: true);
      case EditGesture.trimEnd:
        _applyTrim(gesture, delta, snap, pxPerSec, head: false);
      case EditGesture.roll:
        _applyRoll(gesture, delta, snap, pxPerSec);
      case EditGesture.slip:
        _applySlip(gesture, delta);
      case EditGesture.slide:
        _applySlide(gesture, delta, snap, pxPerSec);
    }
  }

  void _setFeedback(Rt delta, {bool limited = false}) {
    final frames = (delta.micros / frameDuration.micros).round();
    trimFeedback = '${frames >= 0 ? '+' : ''}$frames f';
    trimAtLimit = limited;
  }

  void _applyMove(_Gesture g, Rt delta, int laneDelta, bool snap, double pxPerSec) {
    final origins = g.origins;
    final spanStart = origins.values.map((o) => o.start).reduce((a, b) => a < b ? a : b);
    final spanEnd = origins.values.map((o) => o.end).reduce((a, b) => a > b ? a : b);
    var shift = _snapDelta(
      delta,
      spanStart: spanStart,
      spanEnd: spanEnd,
      exclude: origins.keys.toSet(),
      pxPerSec: pxPerSec,
      enabled: snap,
    );
    if (spanStart.plus(shift) < Rt.zero()) shift = Rt.zero().minus(spanStart);

    // Resolve the target lane for every clip; a move that would drop any clip
    // on an incompatible or locked track is rejected as a whole (TIM-3).
    final targets = <String, String>{};
    for (final entry in origins.entries) {
      final origin = entry.value;
      final fromIndex = g.trackOrder.indexOf(origin.trackId);
      if (fromIndex < 0) return;
      final toIndex = (fromIndex + laneDelta).clamp(0, g.trackOrder.length - 1);
      final target = trackById(g.trackOrder[toIndex]);
      final source = trackById(origin.trackId);
      if (target == null || source == null) return;
      if (target.kind != source.kind || target.lock) return;
      targets[entry.key] = target.id;
    }

    _run('Move clips', (tx) {
      for (final entry in origins.entries) {
        final clip = doc.clipById(entry.key);
        if (clip == null) continue;
        tx.clip(clip.id);
        clip.trackId = targets[entry.key]!;
        clip.start = entry.value.start.plus(shift);
      }
      for (final id in origins.keys) {
        final clip = doc.clipById(id);
        if (clip != null) _pushAside(tx, clip);
      }
    });
    _setFeedback(shift);
  }

  void _applyTrim(_Gesture g, Rt delta, bool snap, double pxPerSec, {required bool head}) {
    final origin = g.origins[g.primaryId];
    if (origin == null) return;
    final edge = head ? origin.start : origin.end;
    var shift = _snapDelta(
      delta,
      spanStart: edge,
      spanEnd: edge,
      exclude: g.origins.keys.toSet(),
      pxPerSec: pxPerSec,
      enabled: snap,
    );
    var limited = false;

    _run('Trim clip', (tx) {
      for (final entry in g.origins.entries) {
        final clip = doc.clipById(entry.key);
        if (clip == null) continue;
        final o = entry.value;
        tx.clip(clip.id);
        if (head) {
          var d = shift;
          if (d < Rt.zero() && Rt.zero().minus(d) > o.sourceIn) {
            d = Rt.zero().minus(o.sourceIn);
            limited = true;
          }
          if (o.start.plus(d) < Rt.zero()) {
            d = Rt.zero().minus(o.start);
            limited = true;
          }
          final maxDelta = o.duration.minus(frameDuration);
          if (d > maxDelta) {
            d = maxDelta;
            limited = true;
          }
          clip.start = o.start.plus(d);
          clip.sourceIn = o.sourceIn.plus(d);
          clip.duration = o.duration.minus(d);
          shift = d;
        } else {
          var duration = o.duration.plus(shift);
          if (duration < frameDuration) {
            duration = frameDuration;
            limited = true;
          }
          final max = _maxDuration(clip, sourceIn: o.sourceIn);
          if (max != null && duration > max) {
            duration = max;
            limited = true;
          }
          clip.duration = duration;
          shift = duration.minus(o.duration);
        }
      }
      for (final id in g.origins.keys) {
        final clip = doc.clipById(id);
        if (clip != null) _pushAside(tx, clip);
      }
    });
    _setFeedback(shift, limited: limited);
  }

  /// Roll: the cut between the primary clip and its right neighbour moves;
  /// the pair's outer bounds stay put (TIM-6).
  void _applyRoll(_Gesture g, Rt delta, bool snap, double pxPerSec) {
    final leftOrigin = g.origins[g.primaryId];
    final left = doc.clipById(g.primaryId);
    if (left == null || leftOrigin == null) return;
    final rightId = g.origins.keys.firstWhereOrNull((id) => id != g.primaryId);
    final right = rightId == null ? null : doc.clipById(rightId);
    final rightOrigin = rightId == null ? null : g.origins[rightId];
    if (right == null || rightOrigin == null) return;

    var shift = _snapDelta(
      delta,
      spanStart: leftOrigin.end,
      spanEnd: leftOrigin.end,
      exclude: g.origins.keys.toSet(),
      pxPerSec: pxPerSec,
      enabled: snap,
    );
    var limited = false;

    // Left clip must keep a frame and stay inside its media…
    final leftMax = _maxDuration(left, sourceIn: leftOrigin.sourceIn);
    if (leftOrigin.duration.plus(shift) < frameDuration) {
      shift = frameDuration.minus(leftOrigin.duration);
      limited = true;
    }
    if (leftMax != null && leftOrigin.duration.plus(shift) > leftMax) {
      shift = leftMax.minus(leftOrigin.duration);
      limited = true;
    }
    // …and so must the right one, which gives back exactly what the left takes.
    if (rightOrigin.duration.minus(shift) < frameDuration) {
      shift = rightOrigin.duration.minus(frameDuration);
      limited = true;
    }
    if (rightOrigin.sourceIn.plus(shift) < Rt.zero()) {
      shift = Rt.zero().minus(rightOrigin.sourceIn);
      limited = true;
    }

    final applied = shift;
    _run('Roll edit', (tx) {
      tx.clip(left.id);
      tx.clip(right.id);
      left.duration = leftOrigin.duration.plus(applied);
      right.start = rightOrigin.start.plus(applied);
      right.sourceIn = rightOrigin.sourceIn.plus(applied);
      right.duration = rightOrigin.duration.minus(applied);
    });
    _setFeedback(applied, limited: limited);
  }

  /// Slip: the content shifts inside a fixed span (Alt-drag body, TIM-6).
  void _applySlip(_Gesture g, Rt delta) {
    final origin = g.origins[g.primaryId];
    final clip = doc.clipById(g.primaryId);
    if (clip == null || origin == null) return;
    var shift = Rt.zero().minus(delta);
    var limited = false;
    if (origin.sourceIn.plus(shift) < Rt.zero()) {
      shift = Rt.zero().minus(origin.sourceIn);
      limited = true;
    }
    final limit = _sourceLimit(clip);
    if (limit != null) {
      final maxIn = limit.minus(clip.sourceSpan);
      if (origin.sourceIn.plus(shift) > maxIn) {
        shift = maxIn.minus(origin.sourceIn);
        limited = true;
      }
    }
    final applied = shift;
    _run('Slip clip', (tx) {
      tx.clip(clip.id);
      clip.sourceIn = origin.sourceIn.plus(applied);
    });
    _setFeedback(applied, limited: limited);
  }

  /// Slide: the clip moves between its neighbours, which absorb the change
  /// (Cmd-drag body, TIM-6).
  void _applySlide(_Gesture g, Rt delta, bool snap, double pxPerSec) {
    final origin = g.origins[g.primaryId];
    final clip = doc.clipById(g.primaryId);
    if (clip == null || origin == null) return;
    final lane = doc.clipsOn(origin.trackId);
    final index = lane.indexWhere((c) => c.id == clip.id);
    final left = index > 0 ? lane[index - 1] : null;
    final right = index >= 0 && index < lane.length - 1 ? lane[index + 1] : null;
    final leftOrigin = left == null ? null : g.origins[left.id] ?? ClipTiming.of(left);
    final rightOrigin = right == null ? null : g.origins[right.id] ?? ClipTiming.of(right);

    var shift = _snapDelta(
      delta,
      spanStart: origin.start,
      spanEnd: origin.end,
      exclude: {clip.id, if (left != null) left.id, if (right != null) right.id},
      pxPerSec: pxPerSec,
      enabled: snap,
    );
    var limited = false;

    if (leftOrigin != null) {
      final min = frameDuration.minus(leftOrigin.duration);
      if (shift < min) {
        shift = min;
        limited = true;
      }
      final leftMax = _maxDuration(left!, sourceIn: leftOrigin.sourceIn);
      if (leftMax != null && leftOrigin.duration.plus(shift) > leftMax) {
        shift = leftMax.minus(leftOrigin.duration);
        limited = true;
      }
    } else if (origin.start.plus(shift) < Rt.zero()) {
      shift = Rt.zero().minus(origin.start);
      limited = true;
    }
    if (rightOrigin != null) {
      final max = rightOrigin.duration.minus(frameDuration);
      if (shift > max) {
        shift = max;
        limited = true;
      }
      if (rightOrigin.sourceIn.plus(shift) < Rt.zero()) {
        shift = Rt.zero().minus(rightOrigin.sourceIn);
        limited = true;
      }
    }

    final applied = shift;
    _run('Slide clip', (tx) {
      tx.clip(clip.id);
      clip.start = origin.start.plus(applied);
      if (left != null && leftOrigin != null) {
        tx.clip(left.id);
        left.duration = leftOrigin.duration.plus(applied);
      }
      if (right != null && rightOrigin != null) {
        tx.clip(right.id);
        right.start = rightOrigin.start.plus(applied);
        right.sourceIn = rightOrigin.sourceIn.plus(applied);
        right.duration = rightOrigin.duration.minus(applied);
      }
    });
    _setFeedback(applied, limited: limited);
  }

  // --- Direct (non-gesture) edits ------------------------------------------

  /// Absolute move, used by tests and by keyboard nudges.
  void moveClip(
    String id, {
    String? trackId,
    required Rt start,
    bool snap = true,
    double pxPerSec = 40,
  }) {
    final clip = doc.clipById(id);
    if (clip == null) return;
    final target = trackById(trackId ?? clip.trackId);
    final source = trackById(clip.trackId);
    if (target == null || source == null || target.kind != source.kind) return;
    if (target.lock || source.lock) return;
    var newStart = snapTime(start, exclude: {id}, pxPerSec: pxPerSec, enabled: snap);
    if (newStart < Rt.zero()) newStart = Rt.zero();
    if (clip.trackId == target.id && clip.start == newStart) return;
    _run('Move clip', (tx) {
      tx.clip(clip.id);
      clip.trackId = target.id;
      clip.start = newStart;
      _pushAside(tx, clip);
    });
  }

  /// Frame-exact head/tail entry from the inspector (TIM-8).
  void setClipTiming(
    String id, {
    Rt? start,
    Rt? duration,
    Rt? sourceIn,
  }) {
    final clip = doc.clipById(id);
    if (clip == null || _locked(clip.trackId)) return;
    _run('Set clip timing', (tx) {
      tx.clip(clip.id);
      if (start != null) clip.start = start < Rt.zero() ? Rt.zero() : start;
      if (sourceIn != null) {
        final limit = _sourceLimit(clip);
        var value = sourceIn < Rt.zero() ? Rt.zero() : sourceIn;
        if (limit != null && value > limit.minus(frameDuration)) {
          value = limit.minus(frameDuration);
        }
        clip.sourceIn = value;
      }
      if (duration != null) {
        var value = duration < frameDuration ? frameDuration : duration;
        final max = _maxDuration(clip);
        if (max != null && value > max) value = max;
        clip.duration = value;
      }
      _pushAside(tx, clip);
    });
  }

  void trimStart(String id, Rt newStart, {bool snap = true, double pxPerSec = 40}) {
    final clip = doc.clipById(id);
    if (clip == null) return;
    beginDrag(EditGesture.trimStart, id);
    updateDrag(newStart.minus(clip.start).seconds, snap: snap, pxPerSec: pxPerSec);
    endGesture();
  }

  void trimEnd(String id, Rt newEnd, {bool snap = true, double pxPerSec = 40}) {
    final clip = doc.clipById(id);
    if (clip == null) return;
    beginDrag(EditGesture.trimEnd, id);
    updateDrag(newEnd.minus(clip.end).seconds, snap: snap, pxPerSec: pxPerSec);
    endGesture();
  }

  // --- Split (TIM-10) -------------------------------------------------------

  String? _splitInto(EditTransaction tx, Clip clip, Rt t) {
    final head = t.minus(clip.start);
    if (head < frameDuration || clip.duration.minus(head) < frameDuration) return null;
    tx.clip(clip.id);
    final right = clip.cloneWithNewId(start: t, linkedGroup: clip.linkedGroup);
    right.sourceIn = clip.sourceIn.plus(head);
    right.duration = clip.duration.minus(head);
    clip.duration = head;
    doc.clips.add(right);
    tx.clip(right.id);
    return right.id;
  }

  String? splitClip(Clip clip, Rt t) =>
      _run('Split clip', (tx) => _splitInto(tx, clip, t));

  /// Splits the selection, or everything under the playhead when nothing is
  /// selected. Linked clips split together.
  List<String> splitAtPlayhead() {
    final under = doc.clips
        .where((c) => playhead > c.start && playhead < c.end && !_locked(c.trackId))
        .toList();
    if (under.isEmpty) return const [];
    final selected = under.where((c) => selection.contains(c.id)).toList();
    final targets = <Clip>{...(selected.isEmpty ? under : selected)};
    for (final clip in targets.toList()) {
      for (final linked in doc.linkedWith(clip)) {
        if (playhead > linked.start && playhead < linked.end) targets.add(linked);
      }
    }
    return _run('Split clips', (tx) {
      final created = <String>[];
      for (final clip in targets) {
        final id = _splitInto(tx, clip, playhead);
        if (id != null) created.add(id);
      }
      return created;
    });
  }

  // --- Delete (TIM-9) -------------------------------------------------------

  void deleteClips(Iterable<String> ids, {bool? ripple}) {
    final doRipple = ripple ?? magnetic;
    final clips = ids.map(doc.clipById).whereType<Clip>().where((c) => !_locked(c.trackId));
    final targets = <Clip>{};
    for (final c in clips) {
      targets.addAll(doc.linkedWith(c));
    }
    if (targets.isEmpty) return;
    _run(doRipple ? 'Ripple delete' : 'Delete clips', (tx) {
      final byTrack = <String, List<Clip>>{};
      for (final c in targets) {
        byTrack.putIfAbsent(c.trackId, () => []).add(c);
        tx.clip(c.id);
        doc.clips.remove(c);
        selection.remove(c.id);
      }
      if (!doRipple) return;
      // Ripple pulls later clips left on the affected tracks only, so tracks
      // the selection did not span keep their sync (TIM-9).
      byTrack.forEach((trackId, removed) {
        removed.sort((a, b) => a.start.compareTo(b.start));
        for (final gap in removed.reversed) {
          for (final c in doc.clipsOn(trackId)) {
            if (c.start >= gap.end) {
              tx.clip(c.id);
              c.start = c.start.minus(gap.duration);
            }
          }
        }
      });
    });
  }

  void deleteClip(String id, {bool? ripple}) => deleteClips([id], ripple: ripple);

  void deleteSelected({bool? ripple}) => deleteClips(selection.toList(), ripple: ripple);

  // --- Clipboard (TIM-17) ---------------------------------------------------

  void copySelection() {
    final clips = selectedClips;
    if (clips.isEmpty) return;
    _clipboard
      ..clear()
      ..addAll(clips.map((c) => c.toJson()));
    _clipboardOrigin = clips.map((c) => c.start).reduce((a, b) => a < b ? a : b);
    notifyListeners();
  }

  void cutSelection() {
    copySelection();
    deleteSelected();
  }

  /// Pastes at the playhead on the original tracks, pushing neighbours right.
  /// A track that no longer exists is recreated (TIM-17 edge case).
  List<String> paste() {
    if (_clipboard.isEmpty) return const [];
    return _run('Paste', (tx) {
      final created = <String>[];
      final groups = <String, String>{};
      for (final json in _clipboard) {
        final source = Clip.fromJson(json);
        var trackId = source.trackId;
        if (doc.trackById(trackId) == null) {
          final track = _createTrack(tx, 'video', restoreId: trackId);
          trackId = track.id;
        }
        if (_locked(trackId)) continue;
        final offset = source.start.minus(_clipboardOrigin);
        final clone = source.cloneWithNewId(
          trackId: trackId,
          start: playhead.plus(offset),
          linkedGroup: source.linkedGroup == null
              ? null
              : groups.putIfAbsent(source.linkedGroup!, generateId),
        );
        doc.clips.add(clone);
        tx.clip(clone.id);
        _pushAside(tx, clone);
        created.add(clone.id);
      }
      selection
        ..clear()
        ..addAll(created);
      return created;
    });
  }

  // --- Clip properties ------------------------------------------------------

  /// Per-clip audio settings; fades keep the AUD spec's shape even though the
  /// mixer itself lands in M3.
  void setClipAudio(String id, {bool? mute, double? volume, double? pan}) {
    final clip = doc.clipById(id);
    if (clip == null) return;
    _run('Clip audio', (tx) {
      tx.clip(id);
      if (mute != null) clip.mute = mute;
      if (volume != null) clip.volume = volume.clamp(0.0, 4.0);
      if (pan != null) clip.pan = pan.clamp(-1.0, 1.0);
    });
  }

  void setClipFades(String id, {Rt? fadeIn, Rt? fadeOut}) {
    final clip = doc.clipById(id);
    if (clip == null) return;
    _run('Clip fades', (tx) {
      tx.clip(id);
      if (fadeIn != null) {
        clip.fadeIn.duration = fadeIn > clip.duration ? clip.duration : fadeIn;
      }
      if (fadeOut != null) {
        clip.fadeOut.duration = fadeOut > clip.duration ? clip.duration : fadeOut;
      }
    });
  }

  void renameClip(String id, String label) {
    final clip = doc.clipById(id);
    if (clip == null || label.trim().isEmpty) return;
    _run('Rename clip', (tx) {
      tx.clip(id);
      clip.label = label.trim();
    });
  }

  /// TIM-9 magnetic mode toggle.
  void setMagnetic(bool value) {
    if (magnetic == value) return;
    magnetic = value;
    notifyListeners();
  }

  /// Copies the selection in place, offset to just after it (⌘D). The spec's
  /// Alt-drag duplicate collides with Alt-drag slip (TIM-3 vs TIM-6), so the
  /// verb lives on a shortcut and the context menu instead.
  List<String> duplicateSelection() {
    final clips = selectedClips;
    if (clips.isEmpty) return const [];
    final origin = clips.map((c) => c.start).reduce((a, b) => a < b ? a : b);
    final end = clips.map((c) => c.end).reduce((a, b) => a > b ? a : b);
    final shift = end.minus(origin);
    return _run('Duplicate clips', (tx) {
      final created = <String>[];
      final groups = <String, String>{};
      for (final clip in clips) {
        if (_locked(clip.trackId)) continue;
        final clone = clip.cloneWithNewId(
          start: clip.start.plus(shift),
          linkedGroup: clip.linkedGroup == null
              ? null
              : groups.putIfAbsent(clip.linkedGroup!, generateId),
        );
        doc.clips.add(clone);
        tx.clip(clone.id);
        _pushAside(tx, clone);
        created.add(clone.id);
      }
      selection
        ..clear()
        ..addAll(created);
      return created;
    });
  }

  // --- Linking (TIM-3) ------------------------------------------------------

  void linkSelection() {
    if (selection.length < 2) return;
    final group = generateId();
    _run('Link clips', (tx) {
      for (final id in selection) {
        final clip = doc.clipById(id);
        if (clip == null) continue;
        tx.clip(id);
        clip.linkedGroup = group;
      }
    });
  }

  void unlinkSelection() {
    _run('Unlink clips', (tx) {
      for (final id in selection) {
        final clip = doc.clipById(id);
        if (clip == null || clip.linkedGroup == null) continue;
        for (final linked in doc.linkedWith(clip)) {
          tx.clip(linked.id);
          linked.linkedGroup = null;
        }
      }
    });
  }

  // --- Tracks (TIM-1/2) -----------------------------------------------------

  Track _createTrack(EditTransaction tx, String kind, {String? restoreId, int? index}) {
    final peers = doc.tracks.where((t) => t.kind == kind).toList();
    final track = Track(
      id: restoreId ?? generateId(),
      kind: kind,
      name: '${kind == 'video' ? 'V' : 'A'}${peers.length + 1}',
      index: index ?? peers.length,
      height: kind == 'video' ? TrackHeight.medium.pixels.toInt() : 56,
    );
    doc.tracks.add(track);
    tx.track(track.id);
    return track;
  }

  Track addTrack(String kind) => _run('Add track', (tx) => _createTrack(tx, kind));

  /// Removes a track and its clips. The last track of a kind stays, since the
  /// document needs somewhere to put media (§10.5).
  void removeTrack(String id) {
    final track = doc.trackById(id);
    if (track == null) return;
    if (doc.tracks.where((t) => t.kind == track.kind).length <= 1) return;
    _run('Remove track', (tx) {
      for (final c in doc.clipsOn(id)) {
        tx.clip(c.id);
        doc.clips.remove(c);
        selection.remove(c.id);
      }
      tx.track(id);
      doc.tracks.remove(track);
      _renumber(tx, track.kind);
    });
  }

  void renameTrack(String id, String name) {
    final track = doc.trackById(id);
    if (track == null || name.trim().isEmpty || track.name == name.trim()) return;
    _run('Rename track', (tx) {
      tx.track(id);
      track.name = name.trim();
    });
  }

  void setTrackFlags(String id, {bool? mute, bool? solo, bool? lock, bool? hidden}) {
    final track = doc.trackById(id);
    if (track == null) return;
    _run('Track settings', (tx) {
      tx.track(id);
      if (mute != null) track.mute = mute;
      if (lock != null) track.lock = lock;
      if (hidden != null) track.hidden = hidden;
      if (solo != null) {
        track.solo = solo;
        // Solo on an audio track mutes the others (TIM-2).
        if (solo && !track.isVideo) {
          for (final other in doc.audioTracks) {
            if (other.id == id) continue;
            tx.track(other.id);
            other.solo = false;
          }
        }
      }
    });
  }

  void setTrackHeight(String id, TrackHeight height) {
    final track = doc.trackById(id);
    if (track == null) return;
    _run('Track height', (tx) {
      tx.track(id);
      track.height = height.pixels.toInt();
    });
  }

  /// Moves a track within its kind. [delta] is in lane steps (negative = up).
  void reorderTrack(String id, int delta) {
    final track = doc.trackById(id);
    if (track == null || delta == 0) return;
    final peers = (track.isVideo ? doc.videoTracks : doc.audioTracks).toList();
    final from = peers.indexWhere((t) => t.id == id);
    final to = (from + delta).clamp(0, peers.length - 1);
    if (from == to) return;
    _run('Reorder tracks', (tx) {
      final moved = peers.removeAt(from);
      peers.insert(to, moved);
      for (var i = 0; i < peers.length; i++) {
        tx.track(peers[i].id);
        peers[i].index = i;
      }
    });
  }

  void _renumber(EditTransaction tx, String kind) {
    final peers = (kind == 'video' ? doc.videoTracks : doc.audioTracks).toList();
    for (var i = 0; i < peers.length; i++) {
      tx.track(peers[i].id);
      peers[i].index = i;
    }
  }

  // --- Media placement (TIM-5) ---------------------------------------------

  /// Puts an asset on the timeline. Video assets with sound also lay their
  /// audio onto the first free audio track and the two are linked.
  List<String> placeAsset(
    String assetId, {
    String? trackId,
    Rt? at,
    DropMode mode = DropMode.append,
    bool withAudio = true,
  }) {
    final asset = doc.assetById(assetId);
    if (asset == null) return const [];
    final videoTarget = trackById(trackId) ??
        (asset.type == 'audio' ? doc.audioTrack() : doc.videoTrack());
    if (videoTarget == null || videoTarget.lock) return const [];
    final duration = asset.duration.isZero ? Rt.fromSeconds(5) : asset.duration;

    return _run('Add clip', (tx) {
      var start = at ?? playhead;
      if (mode == DropMode.append) {
        start = Rt.zero();
        for (final c in doc.clipsOn(videoTarget.id)) {
          if (c.end > start) start = c.end;
        }
      }
      final created = <String>[];
      final group = (asset.type == 'video' && asset.hasAudio && withAudio)
          ? generateId()
          : null;

      Clip place(Track track) {
        final clip = Clip(
          id: generateId(),
          trackId: track.id,
          mediaId: assetId,
          label: asset.name,
          start: start,
          duration: duration,
          sourceIn: Rt.zero(),
          linkedGroup: group,
        );
        switch (mode) {
          case DropMode.insert:
            for (final c in doc.clipsOn(track.id)) {
              if (c.end > start) {
                tx.clip(c.id);
                c.start = c.start.plus(duration);
              }
            }
          case DropMode.overwrite:
            _clearRange(tx, track.id, start, start.plus(duration));
          case DropMode.append:
            break;
        }
        doc.clips.add(clip);
        tx.clip(clip.id);
        created.add(clip.id);
        return clip;
      }

      place(videoTarget);
      if (group != null) {
        final audioTrack = doc.audioTracks.firstOrNull ?? _createTrack(tx, 'audio');
        if (!audioTrack.lock) place(audioTrack);
      }
      selection
        ..clear()
        ..addAll(created);
      return created;
    });
  }

  // --- Markers (TIM-11) -----------------------------------------------------

  Marker addMarker({String name = ''}) => _run('Add marker', (tx) {
        final marker = Marker(id: generateId(), time: playhead, name: name);
        doc.markers.add(marker);
        tx.marker(marker.id);
        return marker;
      });

  void moveMarker(String id, Rt time) {
    final marker = doc.markers.firstWhereOrNull((m) => m.id == id);
    if (marker == null) return;
    _run('Move marker', (tx) {
      tx.marker(id);
      marker.time = time < Rt.zero() ? Rt.zero() : time;
    });
  }

  void renameMarker(String id, String name) {
    final marker = doc.markers.firstWhereOrNull((m) => m.id == id);
    if (marker == null) return;
    _run('Rename marker', (tx) {
      tx.marker(id);
      marker.name = name;
    });
  }

  void removeMarker(String id) {
    final marker = doc.markers.firstWhereOrNull((m) => m.id == id);
    if (marker == null) return;
    _run('Remove marker', (tx) {
      tx.marker(id);
      doc.markers.remove(marker);
    });
  }

  Rt? nextMarker(Rt from, {bool forward = true}) {
    final times = doc.markers.map((m) => m.time).sorted((a, b) => a.compareTo(b));
    return forward
        ? times.firstWhereOrNull((t) => t > from)
        : times.lastWhereOrNull((t) => t < from);
  }

  // --- In / out points (TIM-12) --------------------------------------------

  void setInPoint([Rt? t]) {
    inPoint = t ?? playhead;
    if (outPoint != null && outPoint! <= inPoint!) outPoint = null;
    notifyListeners();
  }

  void setOutPoint([Rt? t]) {
    outPoint = t ?? playhead;
    if (inPoint != null && inPoint! >= outPoint!) inPoint = null;
    notifyListeners();
  }

  void clearInOut() {
    inPoint = null;
    outPoint = null;
    notifyListeners();
  }

  /// Nearest cut point or marker, for PageUp/PageDown (TIM-12).
  Rt? nextEdge(Rt from, {bool forward = true}) {
    final edges = <Rt>{Rt.zero()};
    for (final c in doc.clips) {
      edges.add(c.start);
      edges.add(c.end);
    }
    for (final m in doc.markers) {
      edges.add(m.time);
    }
    final sorted = edges.sorted((a, b) => a.compareTo(b));
    return forward
        ? sorted.firstWhereOrNull((e) => e > from)
        : sorted.lastWhereOrNull((e) => e < from);
  }
}
