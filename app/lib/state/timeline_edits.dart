import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'package:crazycut_app/data/clip_transform.dart';
import 'package:crazycut_app/data/param_value.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/data/text_content.dart';
import 'package:crazycut_app/data/transition.dart';
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

  factory ClipTiming.of(Clip c) =>
      ClipTiming(c.trackId, c.start, c.duration, c.sourceIn);

  final String trackId;
  final Rt start;
  final Rt duration;
  final Rt sourceIn;

  Rt get end => start.plus(duration);
}

class _Gesture {
  _Gesture(
    this.kind,
    this.primaryId,
    this.origins,
    this.trackOrder, {
    this.breakLinks = false,
  });

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

  /// AUD-6: whether adding a video with sound also lays its audio on an audio
  /// track, linked to the picture. Off means picture only — the video clip
  /// keeps its own sound and nothing lands on the audio lane.
  bool linkAudioOnAdd = true;

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
  Clip? get selectedClip =>
      selection.isEmpty ? null : doc.clipById(selection.first);
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

  /// Runs [body] as one undoable edit. Exposed for sibling mixins (audio,
  /// export) so every mutation still lands on the same command stack.
  T runEdit<T>(String label, T Function(EditTransaction tx) body) =>
      _run(label, body);

  T _run<T>(String label, T Function(EditTransaction tx) body) {
    final open = _openTx;
    final tx = open ?? EditTransaction(doc, label);
    final result = body(tx);
    // Timing edits can eat the handles a transition is consuming; every
    // transaction gets one sanitize pass so `overlap == duration` (§5)
    // survives without each call-site remembering to ask.
    sanitizeTransitions(tx);
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
  ///
  /// A transaction still open here belongs to a gesture that never closed —
  /// a cancelled pointer, a disposed widget. Commit it rather than adopting
  /// it: an inherited transaction never reaches the history stack, so every
  /// later edit becomes invisible to undo.
  void beginGesture([String label = 'Edit']) {
    final stale = _openTx;
    if (stale != null) {
      _openTx = null;
      _commit(stale);
    }
    _openTx = EditTransaction(doc, label);
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
    // Never step the history stack with an edit still uncommitted: the open
    // transaction would not be on the stack yet, so undo would revert an
    // older command and leave the newest edit applied.
    endGesture();
    final command = history.undo(doc);
    if (command == null) return;
    _afterHistory();
  }

  void redo() {
    endGesture();
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
    final startSnap = snapTime(
      spanStart.plus(delta),
      exclude: exclude,
      pxPerSec: pxPerSec,
      enabled: true,
    );
    final startIndicator = snapIndicator;
    final startShift = startSnap.minus(spanStart.plus(delta));
    final endSnap = snapTime(
      spanEnd.plus(delta),
      exclude: exclude,
      pxPerSec: pxPerSec,
      enabled: true,
    );
    final endIndicator = snapIndicator;
    final endShift = endSnap.minus(spanEnd.plus(delta));

    if (startShift.isZero && endShift.isZero) {
      snapIndicator = null;
      return delta;
    }
    if (endShift.isZero ||
        (!startShift.isZero &&
            startShift.micros.abs() <= endShift.micros.abs())) {
      snapIndicator = startIndicator;
      return delta.plus(startShift);
    }
    snapIndicator = endIndicator;
    return delta.plus(endShift);
  }

  // --- Overlap policy (TIM-4) ----------------------------------------------

  /// True when a transition deliberately overlaps [a] and [b], so neither may
  /// be slid out from under the span. sanitizeTransitions re-seats those.
  bool _partnered(Clip a, Clip b) => doc.transitions.any(
    (t) =>
        (t.aClipId == a.id && t.bClipId == b.id) ||
        (t.bClipId == a.id && t.aClipId == b.id),
  );

  /// The earliest start [anchor] may take on [trackId] without landing on top
  /// of a clip that begins before [desiredStart].
  ///
  /// Such a clip is a *predecessor*: sliding it right to make room would jump
  /// it past the clip the user is placing, which reads as the two swapping
  /// places. The clip being placed gives way instead, so overshooting a drag
  /// lands it flush against its predecessor rather than inverting the pair.
  Rt _floorFor(
    Clip anchor,
    String trackId,
    Rt desiredStart, {
    Set<String> moving = const {},
  }) {
    var floor = desiredStart;
    for (final c in doc.clipsOn(trackId)) {
      if (c.id == anchor.id || moving.contains(c.id)) continue;
      if (c.start >= desiredStart) break; // sorted by start
      if (_partnered(anchor, c)) continue;
      if (c.end > floor) floor = c.end;
    }
    return floor;
  }

  /// Slides everything colliding with [anchor] to the right, cascading down
  /// the lane. Manual drags can never create an overlap.
  ///
  /// Only clips that begin at or after the anchor are pushed; a predecessor
  /// pins the anchor instead (see [_floorFor]).
  void _pushAside(EditTransaction tx, Clip anchor) {
    final requested = anchor.start;
    final floor = _floorFor(anchor, anchor.trackId, requested);
    if (floor > anchor.start) {
      tx.clip(anchor.id);
      anchor.start = floor;
    }
    var frontier = anchor.end;
    for (final c in doc.clipsOn(anchor.trackId)) {
      if (c.id == anchor.id) continue;
      if (c.start < requested) continue;
      if (_partnered(anchor, c) && c.start < anchor.end) continue;
      if (c.start < frontier) {
        tx.clip(c.id);
        c.start = frontier;
      }
      frontier = c.end;
    }
  }

  /// Clears [from, to) on a track by trimming, splitting or removing whatever
  /// sits there — the overwrite drop mode and overwrite paste.
  void _clearRange(
    EditTransaction tx,
    String trackId,
    Rt from,
    Rt to, {
    Set<String> except = const {},
  }) {
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
        final tail = c.cloneWithNewId(
          start: tailStart,
          linkedGroup: c.linkedGroup,
        );
        tail.sourceIn = c.sourceIn.plus(tailStart.minus(c.start));
        tail.duration = c.end.minus(tailStart);
        c.duration = from.minus(c.start);
        // Touch a newly-created entity before inserting it. Otherwise the
        // transaction records the tail as its "before" state and undo keeps
        // it alive alongside the restored, unsplit source clip.
        tx.clip(tail.id);
        doc.clips.add(tail);
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
  void beginDrag(
    EditGesture kind,
    String primaryId, {
    bool breakLinks = false,
  }) {
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
      {for (final id in movable) id: ClipTiming.of(doc.clipById(id)!)},
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
    _gesture = _Gesture(EditGesture.roll, leftId, {
      leftId: ClipTiming.of(left),
      rightId: ClipTiming.of(right),
    }, laneOrder.map((t) => t.id).toList());
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

  void _applyMove(
    _Gesture g,
    Rt delta,
    int laneDelta,
    bool snap,
    double pxPerSec,
  ) {
    final origins = g.origins;
    final spanStart = origins.values
        .map((o) => o.start)
        .reduce((a, b) => a < b ? a : b);
    final spanEnd = origins.values
        .map((o) => o.end)
        .reduce((a, b) => a > b ? a : b);
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

    // One shift for the whole gesture, so a clip blocked by its predecessor
    // does not slide out of sync with the linked partners moving with it.
    final moving = origins.keys.toSet();
    for (final entry in origins.entries) {
      final clip = doc.clipById(entry.key);
      if (clip == null) continue;
      final desired = entry.value.start.plus(shift);
      final floor = _floorFor(
        clip,
        targets[entry.key]!,
        desired,
        moving: moving,
      );
      final needed = floor.minus(entry.value.start);
      if (needed > shift) shift = needed;
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

  void _applyTrim(
    _Gesture g,
    Rt delta,
    bool snap,
    double pxPerSec, {
    required bool head,
  }) {
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
    final right =
        index >= 0 && index < lane.length - 1 ? lane[index + 1] : null;
    final leftOrigin =
        left == null ? null : g.origins[left.id] ?? ClipTiming.of(left);
    final rightOrigin =
        right == null ? null : g.origins[right.id] ?? ClipTiming.of(right);

    var shift = _snapDelta(
      delta,
      spanStart: origin.start,
      spanEnd: origin.end,
      exclude: {
        clip.id,
        if (left != null) left.id,
        if (right != null) right.id,
      },
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

  // --- Transitions (TRA) ----------------------------------------------------

  /// Refusal reason for the last failed [addTransition], for a UI toast.
  String? lastTransitionError;

  static const _errNoHandles =
      'No extra media at this cut — trim the clips to make room';
  static const _errNotNeighbours = 'Clips must be neighbours on the same track';

  /// Shown when a drop lands on an occupied cut and the caller wants to
  /// explain rather than silently replace.
  static const String kTransitionExists =
      'A transition already exists at this cut';

  /// Sequence seconds of unused source beyond a clip's cut edge, in sequence
  /// time (TRA-10: speed-scaled). Images/text have infinite handles; unknown
  /// or offline media conservatively reports zero.
  double? handleRoom(String clipId, {required bool tail}) {
    final clip = doc.clipById(clipId);
    if (clip == null) return null;
    final asset = doc.assetById(clip.mediaId);
    // Unknown or offline media: no verifiable handles, refuse conservatively.
    if (clip.mediaId.isEmpty || asset == null || asset.offline) return 0.0;
    if (asset.type == 'image' || asset.duration.isZero) return double.infinity;
    final speed = clip.speedValue <= 0 ? 1.0 : clip.speedValue;
    if (tail) {
      final remaining = asset.duration.minus(
        clip.sourceIn.plus(clip.sourceSpan),
      );
      return remaining.micros <= 0 ? 0.0 : remaining.micros / speed / 1000000;
    }
    return clip.sourceIn.micros <= 0
        ? 0.0
        : clip.sourceIn.micros / speed / 1000000;
  }

  Rt? _handleRoomRt(Clip clip, {required bool tail}) {
    final room = handleRoom(clip.id, tail: tail);
    if (room == null) return null;
    if (room.isInfinite) return null; // unbounded
    return Rt.fromMicros((room * 1000000).round());
  }

  Transition? _transitionAt(String aId, String bId) =>
      doc.transitions.firstWhereOrNull(
        (t) =>
            (t.aClipId == aId && t.bClipId == bId) ||
            (t.aClipId == bId && t.bClipId == aId),
      );

  /// Splits requested duration [d] between the two sides honouring
  /// [alignment]; each side clamps to its handles and the remainder flows to
  /// the other side. Returns (aExtend, bExtend), possibly zero on one side.
  (Rt, Rt) _splitExtends(Rt d, Rt? aRoom, Rt? bRoom, String alignment) {
    var aWant = switch (alignment) {
      'start' => Rt.zero(),
      'end' => d,
      _ => d.half(),
    };
    var bWant = d.minus(aWant);
    // First pass: clamp each side to its room, spilling to the other.
    if (aRoom != null && aWant > aRoom) {
      bWant = bWant.plus(aWant.minus(aRoom));
      aWant = aRoom;
    }
    if (bRoom != null && bWant > bRoom) {
      aWant = aWant.plus(bWant.minus(bRoom));
      bWant = bRoom;
    }
    // Second pass in reverse order so asymmetric cuts still fill [d].
    if (bRoom != null && bWant > bRoom) {
      aWant = aWant.plus(bWant.minus(bRoom));
      if (aRoom != null && aWant > aRoom) aWant = aRoom;
      if (aWant > d) aWant = d;
      bWant = bRoom;
    }
    if (aRoom != null && aWant > aRoom) {
      bWant = bWant.plus(aWant.minus(aRoom));
      if (bRoom != null && bWant > bRoom) bWant = bRoom;
      if (bWant > d) bWant = d;
      aWant = aRoom;
    }
    if (aRoom != null && aWant > aRoom) aWant = aRoom;
    if (bRoom != null && bWant > bRoom) bWant = bRoom;
    return (
      aWant < Rt.zero() ? Rt.zero() : aWant,
      bWant < Rt.zero() ? Rt.zero() : bWant,
    );
  }

  /// TRA-2/3/5. Returns the new transition id, or null with
  /// [lastTransitionError] set.
  String? addTransition(
    String aId,
    String bId, {
    String type = 'crossDissolve',
    Rt? duration,
  }) {
    lastTransitionError = null;
    final a = doc.clipById(aId);
    final b = doc.clipById(bId);
    if (a == null || b == null || a.trackId != b.trackId) {
      lastTransitionError = _errNotNeighbours;
      return null;
    }
    final existing = _transitionAt(aId, bId);
    if (existing != null) {
      // TRA-5: dropping onto an existing transition replaces its type,
      // preserving duration and extends.
      setTransitionType(existing.id, type);
      return existing.id;
    }
    final buttJoint =
        b.start >= a.end && b.start.minus(a.end).micros <= frameDuration.micros;
    if (!buttJoint && !(a.end > b.start)) {
      lastTransitionError = _errNotNeighbours;
      return null;
    }
    final aRoom = _handleRoomRt(a, tail: true);
    final bRoom = _handleRoomRt(b, tail: false);
    // TRA-2: refusal is about the SUM of available handles — one side may be
    // empty as long as the other can pay (asymmetric fallback + alignment).
    if ((aRoom != null || bRoom != null) &&
        ((aRoom ?? Rt.zero()) + (bRoom ?? Rt.zero())) < frameDuration) {
      lastTransitionError = _errNoHandles;
      return null;
    }
    // Feasible total is the SUM of both rooms: _splitExtends shifts the
    // shortfall to whichever side can pay (TRA-2 asymmetric fallback).
    final maxDur = (aRoom ?? dMax()).plus(bRoom ?? dMax());
    var want = duration ?? Rt.parse('1/2');
    if (want > maxDur) want = maxDur;
    if (want <= Rt.zero()) {
      lastTransitionError = _errNoHandles;
      return null;
    }
    // Auto alignment when only one side can pay (TRA-2).
    var alignment = 'center';
    if (aRoom == null && bRoom != null) {
      alignment = 'start';
    } else if (aRoom != null && bRoom == null) {
      alignment = 'end';
    } else if (aRoom != null && bRoom != null) {
      if (aRoom < want.half() && bRoom >= want.minus(aRoom)) {
        alignment = 'start';
      }
      if (bRoom < want.half() && aRoom >= want.minus(bRoom)) alignment = 'end';
    }
    var (aExt, bExt) = _splitExtends(want, aRoom, bRoom, alignment);
    final total = aExt.plus(bExt);
    if (total < frameDuration) {
      lastTransitionError = _errNoHandles;
      return null;
    }
    return _run('Add transition', (tx) {
      tx.clip(a.id);
      tx.clip(b.id);
      a.duration = a.duration.plus(aExt);
      b.start = b.start.minus(bExt);
      b.sourceIn = b.sourceIn.minus(bExt.toSourceTime(b.speedValue));
      b.duration = b.duration.plus(bExt);
      final tr = Transition(
        id: generateId(),
        aClipId: a.id,
        bClipId: b.id,
        type: type,
        duration: total,
        alignment: alignment,
        easing: Transition.defaultEasingFor(type),
        aExtend: aExt,
        bExtend: bExt,
      );
      // Snapshot BEFORE the insert so the delta's before-side is null and
      // undo removes the entity instead of re-adding it.
      tx.transition(tr.id);
      doc.transitions.add(tr);
      return tr.id;
    });
  }

  /// Reverses both extends exactly and removes the entity (TRA-4).
  void removeTransition(String id) {
    final tr = doc.transitionById(id);
    if (tr == null) return;
    _run('Remove transition', (tx) {
      _revertExtends(tx, tr);
      tx.transition(id);
      doc.transitions.removeWhere((t) => t.id == id);
    });
  }

  void _revertExtends(EditTransaction tx, Transition tr) {
    final a = doc.clipById(tr.aClipId);
    final b = doc.clipById(tr.bClipId);
    if (a != null) {
      tx.clip(a.id);
      a.duration = (a.duration.minus(tr.aExtend)).atLeast(frameDuration);
    }
    if (b != null) {
      tx.clip(b.id);
      b.start = b.start.plus(tr.bExtend);
      b.sourceIn = b.sourceIn.plus(tr.bExtend.toSourceTime(b.speedValue));
      b.duration = (b.duration.minus(tr.bExtend)).atLeast(frameDuration);
    }
  }

  /// Drops transitions bound to any of [deletedIds], restoring the surviving
  /// side's geometry; both sides gone means just drop the entity.
  void _deleteTransitionsFor(EditTransaction tx, Set<String> deletedIds) {
    for (final tr in doc.transitions.toList()) {
      final aGone = deletedIds.contains(tr.aClipId);
      final bGone = deletedIds.contains(tr.bClipId);
      if (!aGone && !bGone) continue;
      if (aGone && bGone) {
        tx.transition(tr.id);
        doc.transitions.removeWhere((t) => t.id == tr.id);
        continue;
      }
      // Only one side dies: give its consumed handle back to the survivor.
      final survivorIsA = bGone;
      tx.transition(tr.id);
      doc.transitions.removeWhere((t) => t.id == tr.id);
      final a = doc.clipById(tr.aClipId);
      final b = doc.clipById(tr.bClipId);
      if (survivorIsA && a != null) {
        tx.clip(a.id);
        a.duration = (a.duration.minus(tr.aExtend)).atLeast(frameDuration);
      } else if (!survivorIsA && b != null) {
        tx.clip(b.id);
        b.start = b.start.plus(tr.bExtend);
        b.sourceIn = b.sourceIn.plus(tr.bExtend.toSourceTime(b.speedValue));
        b.duration = (b.duration.minus(tr.bExtend)).atLeast(frameDuration);
      }
    }
  }

  /// Retiming (TRA-6): growth consumes more handles per alignment with the
  /// same asymmetric fallback as creation; shrinking returns them keeping the
  /// a:b ratio when both sides paid. Returns '' or a refusal reason.
  String setTransitionDuration(String id, Rt newDur) {
    final tr = doc.transitionById(id);
    if (tr == null) return 'Unknown transition';
    final a = doc.clipById(tr.aClipId);
    final b = doc.clipById(tr.bClipId);
    if (a == null || b == null) return 'Clips missing';
    if (_locked(a.trackId)) return 'Track is locked';
    var target = newDur;
    final minDur = frameDuration;
    if (target < minDur) target = minDur;

    // Room left on top of what is already consumed.
    final aLeft = _handleRoomRt(a, tail: true) ?? dMax();
    final bLeft = _handleRoomRt(b, tail: false) ?? dMax();
    final growing = target > tr.duration;
    // Growing consumes fresh handles from BOTH sides (each pays its own
    // share), so the feasible total is duration + aRoom + bRoom; shrinking
    // always returns handles, feasible down to one frame (TRA-6).
    final feasibleMax =
        growing
            ? tr.duration.plus(aLeft).plus(bLeft)
            : target.clampTo(minDur, tr.duration);
    if (target > feasibleMax) target = feasibleMax;

    var (newA, newB) = _redistribute(target, tr);
    // The overlap invariant is geometric: overlap = min(Aend, Bend) − B.start
    // (for a butt joint at c), and B's far edge c+origDur never moves. A side
    // may not extend past the partner's far edge, so clamp each side by the
    // partner's reach before accepting the split.

    // A's growth may not pass B's far edge: aA ≤ B's original duration.
    final origDurB = b.duration.minus(tr.bExtend);
    if (newA > origDurB) {
      newB = newB.plus(newA.minus(origDurB));
      newA = origDurB;
    }
    var applied = newA.plus(newB);
    if (applied < minDur) return 'No extra media at this cut';
    return _run('Retim transition', (tx) {
      tx.transition(id); // snapshot before mutating (undo ordering)
      _applyExtends(tx, tr, a, b, newA, newB);
      tr.duration = applied;
      tr.alignment = _alignmentFor(tr, newA, newB, applied);
      return '';
    })!;
  }

  /// Drag-friendly variant of [setTransitionDuration]: coalesces into the
  /// open gesture so a drag is one undo step; clamps to feasible range.
  void setTransitionDurationLive(String id, Rt newDur) {
    final tr = doc.transitionById(id);
    final a = tr == null ? null : doc.clipById(tr.aClipId);
    final b = tr == null ? null : doc.clipById(tr.bClipId);
    if (tr == null || a == null || b == null) return;
    if (!inGesture) beginGesture('Retime transition');
    setTransitionDuration(id, newDur);
  }

  /// Distributes [total] over the transition's sides per its alignment,
  /// respecting how much each side already consumed plus remaining room.
  (Rt, Rt) _redistribute(Rt total, Transition tr) {
    final a = doc.clipById(tr.aClipId);
    final b = doc.clipById(tr.bClipId);
    if (a == null || b == null) return (tr.aExtend, tr.bExtend);
    final aRoom = (_handleRoomRt(a, tail: true) ?? dMax()).plus(tr.aExtend);
    final bRoom = (_handleRoomRt(b, tail: false) ?? dMax()).plus(tr.bExtend);
    return _splitExtends(total, aRoom, bRoom, tr.alignment);
  }

  String _alignmentFor(Transition tr, Rt aExt, Rt bExt, Rt total) {
    if (tr.alignment != 'center') return tr.alignment;
    // Centered stays centered unless one side hit zero — then name the side
    // that is absorbing everything so retimes keep working (TRA-2 fallback).
    if (aExt.isZero && !bExt.isZero) return 'start';
    if (bExt.isZero && !aExt.isZero) return 'end';
    return 'center';
  }

  void _applyExtends(
    EditTransaction tx,
    Transition tr,
    Clip a,
    Clip b,
    Rt newA,
    Rt newB,
  ) {
    tx.clip(a.id);
    tx.clip(b.id);
    // Undo the old consumption first, then apply the new split.
    a.duration = a.duration.minus(tr.aExtend);
    b.start = b.start.plus(tr.bExtend);
    b.sourceIn = b.sourceIn.plus(tr.bExtend.toSourceTime(b.speedValue));
    b.duration = b.duration.minus(tr.bExtend);
    a.duration = a.duration.plus(newA);
    b.start = b.start.minus(newB);
    b.sourceIn = b.sourceIn.minus(newB.toSourceTime(b.speedValue));
    b.duration = b.duration.plus(newB);
    tr.aExtend = newA;
    tr.bExtend = newB;
  }

  /// TRA-5: swapping type preserves duration and extends.
  void setTransitionType(String id, String type) {
    final tr = doc.transitionById(id);
    if (tr == null || tr.type == type) return;
    _run('Change transition', (tx) {
      tr.type = type;
      tr.easing = Transition.defaultEasingFor(type);
      tx.transition(id);
    });
  }

  /// Redistributes the current total across the sides per [alignment].
  void setTransitionAlignment(String id, String alignment) {
    final tr = doc.transitionById(id);
    if (tr == null ||
        (alignment != 'center' && alignment != 'start' && alignment != 'end')) {
      return;
    }
    _run('Align transition', (tx) {
      // Snapshot BEFORE mutating so undo can restore geometry + alignment.
      tx.transition(id);
      final old = tr.alignment;
      tr.alignment = alignment;
      final (newA, newB) = _redistribute(tr.duration, tr);
      final a = doc.clipById(tr.aClipId);
      final b = doc.clipById(tr.bClipId);
      if (a == null || b == null) {
        tr.alignment = old;
        return;
      }
      _applyExtends(tx, tr, a, b, newA, newB);
    });
  }

  Rt dMax() => Rt.fromMicros(1 << 40); // "infinite" within int64 safety

  /// Keeps every transition touching a mutated clip consistent with the new
  /// clip geometry (§5 invariant `overlap == duration`). Runs at the end of
  /// any transaction that moved starts/durations/sourceIns:
  /// - shrink extends back onto available handles, moving clips accordingly;
  /// - delete the transition (restoring the joint) when overlap cannot equal
  ///   duration at one frame or more;
  /// - splits strictly inside an overlap restore the joint first.
  void sanitizeTransitions(EditTransaction tx) {
    if (doc.transitions.isEmpty) return;
    for (final tr in doc.transitions.toList()) {
      final a = doc.clipById(tr.aClipId);
      final b = doc.clipById(tr.bClipId);
      // A bound clip vanished inside this transaction: drop the entity.
      if (a == null || b == null) {
        tx.transition(tr.id);
        doc.transitions.removeWhere((t) => t.id == tr.id);
        continue;
      }
      // Only transitions whose anchored clips this transaction mutated can
      // have drifted; untouched pairs (ripple moves, other tracks) stay put.
      if (!(tx.touchedClip(tr.aClipId) || tx.touchedClip(tr.bClipId))) {
        continue;
      }
      final overlap = _overlapOf(a, b);
      if (overlap.isZero) {
        // The joint was pulled apart or fully consumed: restore positions.
        _restoreJoint(tx, tr, a, b);
        continue;
      }
      if (overlap == tr.duration) {
        continue;
      }
      if (overlap < tr.duration) {
        // Handles were eaten: shrink extends (and the clips back with them)
        // so `overlap == duration` holds again.
        _shrinkTransitionTo(tx, tr, a, b, overlap);
        continue;
      }
      // overlap > duration: a trim GAVE media back. Leave the transition as
      // it is for now — growing into freed handles needs the retiming verb
      // (setTransitionDuration), not an automatic side effect of an unrelated
      // trim. The invariant check `overlap == duration` is re-established by
      // the next retim or by removing the transition.
      continue;
    }
  }

  Rt _overlapOf(Clip a, Clip b) {
    final start = a.start > b.start ? a.start : b.start;
    final end = a.end < b.end ? a.end : b.end;
    final d = end.minus(start);
    return d > Rt.zero() ? d : Rt.zero();
  }

  /// Undoes both extends exactly so A|B sit butt-jointed again, then drops
  /// the transition entity.
  void _restoreJoint(EditTransaction tx, Transition tr, Clip a, Clip b) {
    tx.transition(tr.id);
    tx.clip(a.id);
    tx.clip(b.id);
    // Undo both extends exactly; floors keep a pathological document from
    // going negative rather than throwing.
    a.duration = a.duration.minus(tr.aExtend).atLeast(frameDuration);
    b.start = b.start.plus(tr.bExtend);
    b.sourceIn = b.sourceIn.plus(tr.bExtend.toSourceTime(b.speedValue));
    b.duration = b.duration.minus(tr.bExtend).atLeast(frameDuration);
    doc.transitions.removeWhere((t) => t.id == tr.id);
  }

  /// Clamps the transition down to [target]: returns handles the clips no
  /// longer have room for (or that exceed [target]) and deletes the
  /// transition when less than a frame remains.
  void _shrinkTransitionTo(
    EditTransaction tx,
    Transition tr,
    Clip a,
    Clip b,
    Rt target,
  ) {
    if (target < frameDuration) {
      _restoreJoint(tx, tr, a, b);
      return;
    }
    // Re-split [target] per alignment using the CURRENT geometry: the clips
    // may already be inside the old extends, so work from actual edges.
    final aAvail = a.end.minus(_overlapStart(a, b));
    final bAvail = _overlapEnd(a, b).minus(b.start);
    final (newA, newB) = _splitExtends(
      target,
      aAvail.plus(tr.bExtend),
      bAvail.plus(tr.aExtend),
      tr.alignment,
    );
    tx.transition(tr.id);
    a.duration = _overlapStart(a, b).plus(newA).minus(a.start);
    b.start = _overlapEnd(a, b).minus(newB);
    b.duration = b.end.minus(b.start);
    b.sourceIn = b.sourceIn.plus(
      (tr.bExtend.minus(newB)).toSourceTime(b.speedValue),
    );
    tr.aExtend = newA;
    tr.bExtend = newB;
    tr.duration = newA.plus(newB);
  }

  Rt _overlapStart(Clip a, Clip b) => a.start > b.start ? a.start : b.start;
  Rt _overlapEnd(Clip a, Clip b) => a.end < b.end ? a.end : b.end;

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
    var newStart = snapTime(
      start,
      exclude: {id},
      pxPerSec: pxPerSec,
      enabled: snap,
    );
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
  void setClipTiming(String id, {Rt? start, Rt? duration, Rt? sourceIn}) {
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

  void trimStart(
    String id,
    Rt newStart, {
    bool snap = true,
    double pxPerSec = 40,
  }) {
    final clip = doc.clipById(id);
    if (clip == null) return;
    beginDrag(EditGesture.trimStart, id);
    updateDrag(
      newStart.minus(clip.start).seconds,
      snap: snap,
      pxPerSec: pxPerSec,
    );
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
    if (head < frameDuration || clip.duration.minus(head) < frameDuration) {
      return null;
    }
    tx.clip(clip.id);
    final right = clip.cloneWithNewId(start: t, linkedGroup: clip.linkedGroup);
    // The head consumes head × speed of source, not head of source.
    right.sourceIn = clip.sourceIn.plus(head.toSourceTime(clip.speedValue));
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
    final under =
        doc.clips
            .where(
              (c) =>
                  playhead > c.start && playhead < c.end && !_locked(c.trackId),
            )
            .toList();
    if (under.isEmpty) return const [];
    final selected = under.where((c) => selection.contains(c.id)).toList();
    final targets = <Clip>{...(selected.isEmpty ? under : selected)};
    for (final clip in targets.toList()) {
      for (final linked in doc.linkedWith(clip)) {
        if (playhead > linked.start && playhead < linked.end) {
          targets.add(linked);
        }
      }
    }
    return _run('Split clips', (tx) {
      // A split inside a transition span first restores the joint and drops
      // the transition (TRA-4), otherwise the new cut breaks the invariant.
      for (final tr in doc.transitions.toList()) {
        final a = doc.clipById(tr.aClipId);
        final b = doc.clipById(tr.bClipId);
        if (a == null || b == null) continue;
        if (playhead > a.start &&
            playhead < b.end &&
            targets.any((c) => c.id == a.id || c.id == b.id)) {
          _restoreJoint(tx, tr, a, b);
        }
      }
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
    final clips = ids
        .map(doc.clipById)
        .whereType<Clip>()
        .where((c) => !_locked(c.trackId));
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
      // Deleting either anchored clip takes the transition with it; the
      // surviving side gets its consumed handle back first (TRA-4).
      _deleteTransitionsFor(tx, targets.map((c) => c.id).toSet());
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

  void deleteClip(String id, {bool? ripple}) =>
      deleteClips([id], ripple: ripple);

  void deleteSelected({bool? ripple}) =>
      deleteClips(selection.toList(), ripple: ripple);

  // --- Clipboard (TIM-17) ---------------------------------------------------

  void copySelection() {
    final clips = selectedClips;
    if (clips.isEmpty) return;
    _clipboard
      ..clear()
      ..addAll(clips.map((c) => c.toJson()));
    _clipboardOrigin = clips
        .map((c) => c.start)
        .reduce((a, b) => a < b ? a : b);
    _copyAttributesFrom(clips.first);
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
          linkedGroup:
              source.linkedGroup == null
                  ? null
                  : groups.putIfAbsent(source.linkedGroup!, generateId),
        );
        // The id must be touched before the clip exists: a null "before"
        // snapshot is what tells undo to delete it rather than restore it.
        tx.clip(clone.id);
        doc.clips.add(clone);
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
        clip.fadeOut.duration =
            fadeOut > clip.duration ? clip.duration : fadeOut;
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

  /// AUD-6 auto-link toggle: applies to clips added from here on, never to
  /// pairs already on the timeline.
  void setLinkAudioOnAdd(bool value) {
    if (linkAudioOnAdd == value) return;
    linkAudioOnAdd = value;
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
          linkedGroup:
              clip.linkedGroup == null
                  ? null
                  : groups.putIfAbsent(clip.linkedGroup!, generateId),
        );
        // The id must be touched before the clip exists: a null "before"
        // snapshot is what tells undo to delete it rather than restore it.
        tx.clip(clone.id);
        doc.clips.add(clone);
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

  Track _createTrack(
    EditTransaction tx,
    String kind, {
    String? restoreId,
    int? index,
  }) {
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

  Track addTrack(String kind) =>
      _run('Add track', (tx) => _createTrack(tx, kind));

  /// Adds a track inside an open transaction (used when another operation
  /// needs somewhere to put a clip).
  Track addTrackIn(EditTransaction tx, String kind) => _createTrack(tx, kind);

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
      // Transitions anchored on the removed track die with their clips.
      _deleteTransitionsFor(tx, doc.clipsOn(id).map((c) => c.id).toSet());
      tx.track(id);
      doc.tracks.remove(track);
      _renumber(tx, track.kind);
    });
  }

  void renameTrack(String id, String name) {
    final track = doc.trackById(id);
    if (track == null || name.trim().isEmpty || track.name == name.trim()) {
      return;
    }
    _run('Rename track', (tx) {
      tx.track(id);
      track.name = name.trim();
    });
  }

  void setTrackFlags(
    String id, {
    bool? mute,
    bool? solo,
    bool? lock,
    bool? hidden,
  }) {
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
    final peers =
        (kind == 'video' ? doc.videoTracks : doc.audioTracks).toList();
    for (var i = 0; i < peers.length; i++) {
      tx.track(peers[i].id);
      peers[i].index = i;
    }
  }

  // --- Text clips (TXT-1/5) --------------------------------------------------

  /// Animation preset ids for the UI picker (TXT-5).
  static const Map<String, String> kTextPresets = {
    'Fade': 'fade',
    'Pop': 'pop',
    'Slide Left': 'slideLeft',
    'Slide Right': 'slideRight',
    'Slide Up': 'slideUp',
    'Slide Down': 'slideDown',
    'Rise': 'rise',
    'Blink': 'blink',
    'Typewriter': 'typewriter',
  };

  /// Image motion shortcuts (TXT-9). They bake ordinary transform keyframes,
  /// so applying a preset is only a faster way to author editable animation.
  static const Map<String, String> kImagePresets = {
    'Zoom in': 'zoomIn',
    'Zoom out': 'zoomOut',
    'Pan left': 'panLeft',
    'Pan right': 'panRight',
    'Pan up': 'panUp',
    'Pan down': 'panDown',
  };

  /// Entry/exit animations for image clips (label -> id). Both directions
  /// share one id namespace: an id means the same *look*, played forwards on
  /// appear and backwards on disappear.
  static const Map<String, String> kImageEntryPresets = {
    'Fade': 'fade',
    'Pop': 'pop',
    'Slide left': 'slideLeft',
    'Slide right': 'slideRight',
    'Slide up': 'slideUp',
    'Slide down': 'slideDown',
    'Blur': 'blur',
    'Wipe left': 'wipeLeft',
    'Wipe right': 'wipeRight',
    'Wipe up': 'wipeUp',
    'Wipe down': 'wipeDown',
  };

  static const double kImageEntryDefaultSeconds = 0.4;

  /// TXT-1: a text clip at the playhead on the topmost unlocked video track
  /// (or [trackId]), default 5 s, pushed clear of neighbours and selected.
  List<String> addTextClip({String? trackId, Rt? at, Rt? duration}) {
    Track? target;
    if (trackId != null) target = trackById(trackId);
    if (target == null) {
      for (final t in doc.videoTracks.reversed) {
        if (!t.lock) {
          target = t;
          break;
        }
      }
    }
    final lane = target;
    if (lane == null || !lane.isVideo || _locked(lane.id)) return const [];
    final len = duration ?? Rt.fromSeconds(5);
    return _run('Add text', (tx) {
      final clip = Clip(
        id: generateId(),
        trackId: lane.id,
        mediaId: '',
        label: 'Text',
        start: at ?? playhead,
        duration: len < frameDuration ? frameDuration : len,
        sourceIn: Rt.zero(),
        text: TextContent(),
        transform: ClipTransform(),
      );
      doc.clips.add(clip);
      tx.clip(clip.id);
      _pushAside(tx, clip);
      selection
        ..clear()
        ..add(clip.id);
      return [clip.id];
    });
  }

  void setTextContent(String clipId, String content) {
    final clip = doc.clipById(clipId);
    if (clip == null || clip.text == null || _locked(clip.trackId)) return;
    _run('Edit text', (tx) {
      tx.clip(clipId);
      clip.text!.content = content;
    });
  }

  /// One transaction per style change; [mutate] works on a copy so partial
  /// mutations can never half-land.
  void setTextStyle(String clipId, TextContent Function(TextContent) mutate) {
    final clip = doc.clipById(clipId);
    if (clip == null || clip.text == null || _locked(clip.trackId)) return;
    _run('Style text', (tx) {
      tx.clip(clipId);
      clip.text = mutate(clip.text!.copy());
    });
  }

  /// Bakes an animation preset into the clip's TRANSFORM as editable
  /// keyframes (TXT-5); times scale by 1/[speed]. Switching presets first
  /// removes the channels owned by the previous preset, so stale scale or
  /// position keys cannot leak into the newly selected animation.
  void applyTextPreset(String clipId, String preset, {double speed = 1.0}) {
    final clip = doc.clipById(clipId);
    if (clip == null || _locked(clip.trackId)) return;
    final durSec = clip.duration.seconds;
    final scale = speed > 0 ? 1.0 / speed : 1.0;
    Rt at(double seconds) => quantiseToFrame(
      Rt.fromMicros(
        (seconds * scale * 1000000).round().clamp(0, clip.duration.micros),
      ),
    );

    void keys(
      ParamValue pv,
      List<(double, dynamic)> points, {
      String interp = 'linear',
    }) {
      pv.keyframes
        ..clear()
        ..addAll([
          for (final (t, v) in points)
            {'t': at(t).toString(), 'v': v, 'interp': interp},
        ]);
      pv.sortKeys();
      // Interp rides on the LEFT key of each segment; the first segment uses
      // [interp] unless the caller supplied per-point overrides below.
    }

    _run('Apply text animation', (tx) {
      tx.clip(clipId);
      final previous = clip.text?.animation ?? '';
      final tr = clip.transform?.copy() ?? ClipTransform();
      _clearTextPresetChannels(tr, previous);
      // Keep the selected preset visible in the inspector. This is
      // provenance only; baked keyframes remain the playback source of truth.
      clip.text ??= TextContent();
      clip.text!.animation = preset;
      switch (preset) {
        case 'fade':
          keys(
            tr.opacity,
            durSec > 1.5
                ? [(0, 0.0), (0.5, 100.0), (durSec - 0.5, 100.0), (durSec, 0.0)]
                : [(0, 0.0), (0.5, 100.0)],
          );
        case 'pop':
          // Overshoot needs easeOut on the second leg; interps are stored per
          // left key so write them directly.
          tr.scale.keyframes
            ..clear()
            ..addAll([
              {'t': at(0).toString(), 'v': 0.0, 'interp': 'easeOut'},
              {'t': at(0.35).toString(), 'v': 112.0, 'interp': 'linear'},
              {'t': at(0.6).toString(), 'v': 100.0, 'interp': 'linear'},
            ]);
          keys(tr.opacity, [(0, 0.0), (0.25, 100.0)]);
        case 'slideLeft' || 'slideRight' || 'slideUp' || 'slideDown':
          const dist = 120.0;
          final (fromX, fromY) = switch (preset) {
            'slideLeft' => (-dist, 0.0),
            'slideRight' => (dist, 0.0),
            'slideUp' => (0.0, -dist),
            _ => (0.0, dist),
          };
          final horizontal = preset == 'slideLeft' || preset == 'slideRight';
          final movePv = horizontal ? tr.x : tr.y;
          movePv.keyframes
            ..clear()
            ..addAll([
              {
                't': at(0).toString(),
                'v': horizontal ? fromX : fromY,
                'interp': 'easeOut',
              },
              {'t': at(0.5).toString(), 'v': 0.0, 'interp': 'linear'},
            ]);
          keys(tr.opacity, [(0, 0.0), (0.5, 100.0)]);
        case 'rise':
          tr.y.keyframes
            ..clear()
            ..addAll([
              {'t': at(0).toString(), 'v': 80.0, 'interp': 'easeOut'},
              {'t': at(0.5).toString(), 'v': 0.0, 'interp': 'linear'},
            ]);
          keys(tr.opacity, [(0, 0.0), (0.5, 100.0)]);
        case 'blink':
          // Stepped via hold interp: lit → dark at 0.25 → dark to 0.5 → lit.
          final cycle = <(double, double)>[];
          for (var t = 0.0; t < durSec - 1e-9; t += 0.75) {
            cycle.add((t, t));
          }
          tr.opacity.keyframes
            ..clear()
            ..addAll([
              for (final (start, _) in cycle) ...[
                {'t': at(start).toString(), 'v': 100.0, 'interp': 'hold'},
                {'t': at(start + 0.25).toString(), 'v': 0.0, 'interp': 'hold'},
                {
                  't': at(start + 0.75).toString(),
                  'v': 100.0,
                  'interp': 'hold',
                },
              ],
            ]);
          tr.opacity.sortKeys();
        case 'typewriter':
        // Typewriter is evaluated from this provenance flag by the text
        // rasterizer rather than transform keyframes.
        default:
          return;
      }
      clip.transform = tr;
    });
  }

  /// Removes the active text animation and returns its generated transform
  /// channels to their neutral values. This is intentionally a visible choice
  /// in the inspector instead of making the selected preset impossible to
  /// undo without opening the keyframe editor.
  void clearTextPreset(String clipId) {
    final clip = doc.clipById(clipId);
    if (clip == null || clip.text == null || _locked(clip.trackId)) return;
    _run('Remove text animation', (tx) {
      tx.clip(clipId);
      final tr = clip.transform?.copy() ?? ClipTransform();
      _clearTextPresetChannels(tr, clip.text!.animation);
      clip.text!.animation = '';
      clip.transform = tr;
    });
  }

  void _clearTextPresetChannels(ClipTransform tr, String preset) {
    void neutral(ParamValue value, double resting) {
      value.keyframes.clear();
      value.static = resting;
    }

    switch (preset) {
      case 'fade' || 'blink':
        neutral(tr.opacity, 100);
      case 'pop':
        neutral(tr.scale, 100);
        neutral(tr.opacity, 100);
      case 'slideLeft' || 'slideRight':
        neutral(tr.x, 0);
        neutral(tr.opacity, 100);
      case 'slideUp' || 'slideDown' || 'rise':
        neutral(tr.y, 0);
        neutral(tr.opacity, 100);
      case 'typewriter' || '':
        return;
      default:
        return;
    }
  }

  // --- Image animation (TXT-9 motion + entry/exit) ----------------------------
  //
  // The whole animation for an image clip is *generated* from a small spec kept
  // on the clip, rather than merged into whatever keyframes happen to be there:
  //
  //   extra['imageAnim'] = {
  //     'motion': 'zoomIn',                     // full-clip Ken Burns, or null
  //     'in':  {'type': 'pop',  'seconds': 0.4},
  //     'out': {'type': 'fade', 'seconds': 0.4},
  //     'base': {'x': 0, 'y': 0, 'scale': 100, 'opacity': 100},
  //     'fx':   ['<effect instance id>', ...],  // blur/wipe instances we own
  //   }
  //
  // Regenerating from the spec is what makes a preset removable: turning one
  // off rebuilds the curve without it instead of trying to unpick its keys.
  // Only x/y/scale/opacity and the listed effect instances are ever touched —
  // rotation, user effects and hand-authored keys on other params survive.

  static const String _animKey = 'imageAnim';

  /// The transform parameters a generated image animation may write.
  static const List<String> _animParams = ['x', 'y', 'scale', 'opacity'];

  /// The live animation spec for [clip], or null when it has none.
  Map<String, dynamic>? imageAnimSpec(Clip clip) {
    final raw = clip.extra[_animKey];
    return raw is Map<String, dynamic> ? raw : null;
  }

  /// Preset id currently applied on a side ('motion', 'in' or 'out').
  String? imageAnimPreset(Clip clip, String side) {
    final spec = imageAnimSpec(clip);
    if (spec == null) return null;
    if (side == 'motion') return spec['motion'] as String?;
    final entry = spec[side];
    return entry is Map ? entry['type'] as String? : null;
  }

  double imageAnimSeconds(Clip clip, String side) {
    final entry = imageAnimSpec(clip)?[side];
    return entry is Map
        ? ((entry['seconds'] as num?)?.toDouble() ?? kImageEntryDefaultSeconds)
        : kImageEntryDefaultSeconds;
  }

  /// The pose a generated animation plays around, or the clip's plain
  /// transform values when it has no generated animation. Direct manipulation
  /// reads its starting values from here so a drag stays 1:1 with the pointer
  /// even while an entry animation is offsetting the image on screen.
  Map<String, double> imageAnimResting(Clip clip) =>
      _restingValues(clip, imageAnimSpec(clip));

  bool _isImageClip(Clip clip) => doc.assetById(clip.mediaId)?.type == 'image';

  /// TXT-9: full-clip Ken Burns move. Pass null to drop the motion and keep
  /// whatever entry/exit animation is set.
  void applyImagePreset(String clipId, String? preset) {
    final clip = _editableClip(clipId);
    if (clip == null || !_isImageClip(clip)) return;
    _run('Animate image', (tx) {
      tx.clip(clipId);
      final spec = _ensureAnimSpec(clip);
      spec['motion'] = kImagePresets.containsValue(preset) ? preset : null;
      _writeImageAnimation(clip);
    });
  }

  /// Sets the appear and/or disappear animation. Passing `''` for a side
  /// clears it; omitting a side leaves it alone.
  void setImageEntryExit(
    String clipId, {
    String? appear,
    String? disappear,
    double? seconds,
  }) {
    final clip = _editableClip(clipId);
    if (clip == null || !_isImageClip(clip)) return;
    _run('Image animation', (tx) {
      tx.clip(clipId);
      final spec = _ensureAnimSpec(clip);
      void side(String key, String? value) {
        if (value == null) {
          if (seconds != null && spec[key] is Map) {
            (spec[key] as Map)['seconds'] = seconds;
          }
          return;
        }
        if (value.isEmpty || !kImageEntryPresets.containsValue(value)) {
          spec[key] = null;
          return;
        }
        spec[key] = <String, dynamic>{
          'type': value,
          'seconds':
              seconds ??
              ((spec[key] is Map ? (spec[key] as Map)['seconds'] : null)
                      as num?)
                  ?.toDouble() ??
              kImageEntryDefaultSeconds,
        };
      }

      side('in', appear);
      side('out', disappear);
      _writeImageAnimation(clip);
    });
  }

  /// Drops every generated animation and leaves the clip at its resting pose.
  void clearImageAnimation(String clipId) {
    final clip = _editableClip(clipId);
    if (clip == null || !_isImageClip(clip)) return;
    final spec = imageAnimSpec(clip);
    final transform = clip.transform;
    if (transform == null) return;
    final params = <String, ParamValue>{
      'x': transform.x,
      'y': transform.y,
      'scale': transform.scale,
      'opacity': transform.opacity,
    };
    // Only ever undo what a preset generated, so hand-authored keys on an
    // untouched parameter (a manual opacity ramp, say) survive the clear.
    final generated =
        spec == null
            ? [
              for (final e in params.entries)
                if (e.key != 'opacity' && e.value.animated) e.key,
            ]
            : ((spec['params'] as List?) ?? const [])
                .whereType<String>()
                .toList();
    if (generated.isEmpty && spec == null) return;
    final base = _restingValues(clip, spec);
    _run('Clear image animation', (tx) {
      tx.clip(clipId);
      _removeManagedEffects(clip, spec);
      clip.extra.remove(_animKey);
      for (final id in generated) {
        final param = params[id];
        if (param == null) continue;
        param.keyframes.clear();
        // Projects predating the spec have no resting pose recorded, so they
        // keep the old contract: settle on the value the motion ended at.
        param.static = spec == null ? param.evaluate(clip.duration) : base[id];
      }
    });
  }

  Map<String, dynamic> _ensureAnimSpec(Clip clip) {
    final existing = imageAnimSpec(clip);
    if (existing != null) return existing;
    final spec = <String, dynamic>{
      'motion': null,
      'in': null,
      'out': null,
      'base': _restingValues(clip, null),
      'fx': <String>[],
    };
    clip.extra[_animKey] = spec;
    return spec;
  }

  /// The pose the clip rests at between its entry and exit. Taken from the
  /// spec once one exists, so regenerating never drifts; otherwise read off
  /// the clip's current (possibly hand-keyed) transform.
  Map<String, double> _restingValues(Clip clip, Map<String, dynamic>? spec) {
    final stored = spec?['base'];
    if (stored is Map) {
      return {
        for (final key in _animParams)
          key:
              (stored[key] as num?)?.toDouble() ??
              (key == 'scale' || key == 'opacity' ? 100.0 : 0.0),
      };
    }
    final t = clip.transformOrDefault;
    // Read an already-animated param at the middle of the clip, never at its
    // head: t=0 is exactly where an entry animation parks its *start* value, so
    // taking the pose from there made a clip shrink by the pop preset's 0.7
    // every time the pose had to be re-derived.
    final middle = Rt.fromMicros(clip.duration.micros ~/ 2);
    double at(ParamValue pv, double fallback) {
      final v = pv.animated ? pv.evaluate(middle) : pv.static;
      return v is num ? v.toDouble() : fallback;
    }

    return {
      'x': at(t.x, 0),
      'y': at(t.y, 0),
      'scale': at(t.scale, 100),
      'opacity': at(t.opacity, 100),
    };
  }

  /// Keeps the resting pose in sync when the gizmo or an inspector slider
  /// moves a clip whose animation we generate — the animation then replays
  /// around the new pose instead of snapping back to the old one.
  void _syncAnimBase(Clip clip, String paramId, double value) {
    final spec = imageAnimSpec(clip);
    if (spec == null) return;
    if (!_animParams.contains(paramId)) return;
    final base = _restingValues(clip, spec)..[paramId] = value;
    spec['base'] = base;
    _writeImageAnimation(clip);
  }

  void _removeManagedEffects(Clip clip, Map<String, dynamic>? spec) {
    final owned = (spec?['fx'] as List?)?.cast<dynamic>() ?? const [];
    if (owned.isEmpty) return;
    final ids = owned.whereType<String>().toSet();
    clip.effects.removeWhere((e) => e is Map && ids.contains(e['id']));
  }

  /// Regenerates every generated keyframe and managed effect on [clip] from
  /// its spec. Must run inside an open transaction.
  void _writeImageAnimation(Clip clip) {
    final spec = imageAnimSpec(clip);
    if (spec == null) return;
    _removeManagedEffects(clip, spec);
    spec['fx'] = <String>[];

    final base = _restingValues(clip, spec);
    spec['base'] = base;
    final transform = clip.transform ??= ClipTransform();
    final params = <String, ParamValue>{
      'x': transform.x,
      'y': transform.y,
      'scale': transform.scale,
      'opacity': transform.opacity,
    };

    final duration = clip.duration;
    Rt at(double seconds) => quantiseToFrame(
      Rt.fromMicros((seconds * 1000000).round().clamp(0, duration.micros)),
    );
    final durSec = duration.seconds;
    final inType = imageAnimPreset(clip, 'in');
    final outType = imageAnimPreset(clip, 'out');
    // Neither side may eat more than its half of the clip, or a short clip
    // would animate in while it is still animating out.
    final inSec =
        inType == null
            ? 0.0
            : imageAnimSeconds(clip, 'in').clamp(0.05, durSec / 2);
    final outSec =
        outType == null
            ? 0.0
            : imageAnimSeconds(clip, 'out').clamp(0.05, durSec / 2);

    // 1. The resting curve: the Ken Burns move if there is one, else flat.
    final curves = <String, List<Map<String, dynamic>>>{
      for (final key in params.keys) key: <Map<String, dynamic>>[],
    };
    _writeMotionCurve(spec['motion'] as String?, base, curves, at(durSec));

    double valueAt(String key, double seconds) {
      final keys = curves[key]!;
      if (keys.isEmpty) return base[key]!;
      final probe = ParamValue(
        static: base[key],
        keyframes: [
          for (final k in keys) {...k},
        ],
      );
      final v = probe.evaluate(at(seconds));
      return v is num ? v.toDouble() : base[key]!;
    }

    // 2. Entry and exit, layered onto that curve so a slide-in lands exactly
    //    where the resting move wants the image to be.
    final fx = <String, Map<String, List<Map<String, dynamic>>>>{};
    if (inType != null) {
      _writeEdgeAnimation(
        type: inType,
        entering: true,
        edgeSec: inSec,
        restSec: inSec,
        clipSec: durSec,
        base: base,
        curves: curves,
        valueAt: valueAt,
        at: at,
        fx: fx,
      );
    }
    if (outType != null) {
      _writeEdgeAnimation(
        type: outType,
        entering: false,
        edgeSec: outSec,
        restSec: durSec - outSec,
        clipSec: durSec,
        base: base,
        curves: curves,
        valueAt: valueAt,
        at: at,
        fx: fx,
      );
    }

    // 3. Commit. A param with no generated keys goes back to a plain static so
    //    the inspector shows it as un-animated.
    final generated = <String>[];
    for (final entry in params.entries) {
      final keys = curves[entry.key]!;
      entry.value.keyframes
        ..clear()
        ..addAll(keys);
      entry.value.sortKeys();
      // The static value is what the param falls back to once the generated
      // keys go away, so keep it on the resting pose even while it is animated
      // rather than leaving whatever the pose was before the last edit.
      entry.value.static = base[entry.key];
      if (keys.isNotEmpty) generated.add(entry.key);
    }
    spec['params'] = generated;

    // 4. Managed effects. Blur first so the wipe edge stays crisp.
    for (final type in const ['gaussianBlur', 'crop']) {
      final byParam = fx[type];
      if (byParam == null || byParam.isEmpty) continue;
      final instance = <String, dynamic>{
        'id': generateId(),
        'type': type,
        'enabled': true,
        'params': {
          for (final entry in byParam.entries)
            entry.key:
                ParamValue(
                  static: entry.value.first['v'],
                  keyframes: entry.value,
                ).toJson(),
        },
      };
      clip.effects.add(instance);
      (spec['fx'] as List).add(instance['id']);
    }
  }

  /// Ken Burns keys for the resting curve, matching the pre-existing presets:
  /// a slow push or a 15%-oversized slow pan.
  void _writeMotionCurve(
    String? motion,
    Map<String, double> base,
    Map<String, List<Map<String, dynamic>>> curves,
    Rt end,
  ) {
    if (motion == null) return;
    final dx = doc.settings.width * 0.05;
    final dy = doc.settings.height * 0.05;
    final scale = base['scale']!;
    // Multiply before dividing: `scale * 1.15` lands on 114.99999999999999
    // for the default 100, which shows up in the inspector and in goldens.
    double zoom(double percent) => scale * percent / 100;
    void keys(String param, double from, double to) {
      curves[param]!
        ..clear()
        ..addAll([
          {'t': Rt.zero().toString(), 'v': from, 'interp': 'easeInOut'},
          {'t': end.toString(), 'v': to, 'interp': 'linear'},
        ]);
    }

    switch (motion) {
      case 'zoomIn':
        keys('scale', scale, zoom(115));
      case 'zoomOut':
        keys('scale', zoom(115), scale);
      case 'panLeft':
        keys('scale', zoom(115), zoom(115));
        keys('x', base['x']! + dx, base['x']! - dx);
      case 'panRight':
        keys('scale', zoom(115), zoom(115));
        keys('x', base['x']! - dx, base['x']! + dx);
      case 'panUp':
        keys('scale', zoom(115), zoom(115));
        keys('y', base['y']! + dy, base['y']! - dy);
      case 'panDown':
        keys('scale', zoom(115), zoom(115));
        keys('y', base['y']! - dy, base['y']! + dy);
    }
  }

  /// Writes one side of the animation.
  ///
  /// [entering] runs from the clip's head towards [restSec]; otherwise it runs
  /// from [restSec] to the tail. Transform-based looks rewrite the head/tail of
  /// the resting curve; blur and wipe instead accumulate keys in [fx] for a
  /// managed effect instance, because the compositor has no such transform.
  void _writeEdgeAnimation({
    required String type,
    required bool entering,
    required double edgeSec,
    required double restSec,
    required double clipSec,
    required Map<String, double> base,
    required Map<String, List<Map<String, dynamic>>> curves,
    required double Function(String, double) valueAt,
    required Rt Function(double) at,
    required Map<String, Map<String, List<Map<String, dynamic>>>> fx,
  }) {
    final edgeSecClamped = edgeSec.clamp(0.0, clipSec);
    final startSec = entering ? 0.0 : restSec;
    final endSec = entering ? restSec : clipSec;
    // Easing rides on the LEFT key of a segment, so an entry eases out of its
    // extreme and an exit eases into it.
    final interp = entering ? 'easeOut' : 'easeIn';

    /// Replaces the head (or tail) of a param's curve with [points], keeping
    /// the resting value at the boundary.
    void shape(String param, List<(double, double)> points) {
      final keys = curves[param]!;
      keys.removeWhere((k) {
        final t = ParamValue.timeOf(k).seconds;
        return entering ? t < endSec - 1e-9 : t > startSec + 1e-9;
      });
      for (final (seconds, value) in points) {
        keys.removeWhere(
          (k) => (ParamValue.timeOf(k).seconds - seconds).abs() < 1e-9,
        );
        keys.add({
          't': at(seconds).toString(),
          'v': value,
          'interp': seconds < (entering ? endSec : clipSec) ? interp : 'linear',
        });
      }
      keys.sort((a, b) => ParamValue.timeOf(a).compareTo(ParamValue.timeOf(b)));
    }

    /// Fades opacity to zero at the outer edge. Every look uses it: an image
    /// that only slides or blurs still pops at the boundary without it.
    void fade() {
      final rest = valueAt('opacity', entering ? endSec : startSec);
      shape('opacity', [
        if (entering) (0.0, 0.0) else (startSec, rest),
        if (entering) (endSec, rest) else (clipSec, 0.0),
      ]);
    }

    void effectKeys(String effect, String param, double from, double to) {
      final byParam = fx.putIfAbsent(effect, () => {});
      final keys = byParam.putIfAbsent(param, () => []);
      keys.addAll([
        {
          't': at(startSec).toString(),
          'v': entering ? from : to,
          'interp': interp,
        },
        {
          't': at(endSec).toString(),
          'v': entering ? to : from,
          'interp': 'linear',
        },
      ]);
      keys.sort((a, b) => ParamValue.timeOf(a).compareTo(ParamValue.timeOf(b)));
    }

    switch (type) {
      case 'fade':
        fade();
      case 'pop':
        final rest = valueAt('scale', entering ? endSec : startSec);
        if (entering) {
          shape('scale', [
            (0.0, rest * 0.7),
            (edgeSecClamped * 0.75, rest * 1.06),
            (endSec, rest),
          ]);
        } else {
          shape('scale', [(startSec, rest), (clipSec, rest * 0.7)]);
        }
        fade();
      case 'slideLeft' || 'slideRight' || 'slideUp' || 'slideDown':
        final horizontal = type == 'slideLeft' || type == 'slideRight';
        final param = horizontal ? 'x' : 'y';
        final travel =
            (horizontal ? doc.settings.width : doc.settings.height) * 0.25;
        // The named direction is the way the image travels, so an entry starts
        // on the opposite side from where it is headed.
        final away = switch (type) {
          'slideLeft' => entering ? travel : -travel,
          'slideRight' => entering ? -travel : travel,
          'slideUp' => entering ? travel : -travel,
          _ => entering ? -travel : travel,
        };
        final rest = valueAt(param, entering ? endSec : startSec);
        shape(param, [
          if (entering) (0.0, rest + away) else (startSec, rest),
          if (entering) (endSec, rest) else (clipSec, rest + away),
        ]);
        fade();
      case 'blur':
        effectKeys('gaussianBlur', 'radius', 24.0, 0.0);
        fade();
      case 'wipeLeft' || 'wipeRight' || 'wipeUp' || 'wipeDown':
        // crop.<side> is the percentage eaten off that side, so 100 -> 0
        // uncovers the image with the edge travelling that way.
        final side = switch (type) {
          'wipeLeft' => 'left',
          'wipeRight' => 'right',
          'wipeUp' => 'top',
          _ => 'bottom',
        };
        effectKeys('crop', side, 100.0, 0.0);
      default:
        return;
    }
  }

  // --- Effects (FX-1..4, FX-13/14) --------------------------------------------

  /// Engine-shaped fallback catalog (`effects.md`); CrazyCutEngine's
  /// effectCatalog replaces it once wired — same shape either way.
  static const List<Map<String, dynamic>> kFallbackEffectCatalog = [
    {
      'id': 'exposure',
      'label': 'Exposure',
      'category': 'Color',
      'params': [
        {
          'id': 'stops',
          'label': 'Stops',
          'type': 'float',
          'min': -2.0,
          'max': 2.0,
          'default': 0.0,
        },
      ],
    },
    {
      'id': 'contrast',
      'label': 'Contrast',
      'category': 'Color',
      'params': [
        {
          'id': 'amount',
          'label': 'Amount',
          'type': 'float',
          'min': -1.0,
          'max': 1.0,
          'default': 0.0,
        },
      ],
    },
    {
      'id': 'saturation',
      'label': 'Saturation',
      'category': 'Color',
      'params': [
        {
          'id': 'amount',
          'label': 'Amount',
          'type': 'float',
          'min': 0.0,
          'max': 2.0,
          'default': 1.0,
        },
      ],
    },
    {
      'id': 'temperature',
      'label': 'Temperature',
      'category': 'Color',
      'params': [
        {
          'id': 'warmth',
          'label': 'Warmth',
          'type': 'float',
          'min': -1.0,
          'max': 1.0,
          'default': 0.0,
        },
      ],
    },
    {
      'id': 'tint',
      'label': 'Tint',
      'category': 'Color',
      'params': [
        {
          'id': 'balance',
          'label': 'Balance',
          'type': 'float',
          'min': -1.0,
          'max': 1.0,
          'default': 0.0,
        },
      ],
    },
    {
      'id': 'fade',
      'label': 'Fade',
      'category': 'Color',
      'params': [
        {
          'id': 'amount',
          'label': 'Amount',
          'type': 'float',
          'min': 0.0,
          'max': 1.0,
          'default': 0.0,
        },
      ],
    },
    {
      'id': 'vignette',
      'label': 'Vignette',
      'category': 'Color',
      'params': [
        {
          'id': 'amount',
          'label': 'Amount',
          'type': 'float',
          'min': 0.0,
          'max': 1.0,
          'default': 0.35,
        },
        {
          'id': 'roundness',
          'label': 'Roundness',
          'type': 'float',
          'min': 0.0,
          'max': 1.0,
          'default': 0.5,
        },
        {
          'id': 'softness',
          'label': 'Softness',
          'type': 'float',
          'min': 0.0,
          'max': 1.0,
          'default': 0.5,
        },
      ],
    },
    {
      'id': 'gaussianBlur',
      'label': 'Gaussian Blur',
      'category': 'Blur & Style',
      'params': [
        {
          'id': 'radius',
          'label': 'Radius',
          'type': 'float',
          'min': 0.0,
          'max': 100.0,
          'default': 8.0,
          'unit': 'px@1080',
        },
      ],
    },
    {
      'id': 'boxBlur',
      'label': 'Box Blur',
      'category': 'Blur & Style',
      'params': [
        {
          'id': 'radius',
          'label': 'Radius',
          'type': 'float',
          'min': 0.0,
          'max': 100.0,
          'default': 8.0,
          'unit': 'px@1080',
        },
        {
          'id': 'iterations',
          'label': 'Iterations',
          'type': 'enum',
          'min': 1,
          'max': 4,
          'default': 2,
          'static': true,
          'options': [1, 2, 3, 4],
        },
      ],
    },
    {
      'id': 'pixelate',
      'label': 'Pixelate',
      'category': 'Blur & Style',
      'params': [
        {
          'id': 'cell',
          'label': 'Cell Size',
          'type': 'float',
          'min': 2.0,
          'max': 128.0,
          'default': 12.0,
          'unit': 'px@1080',
        },
      ],
    },
    {
      'id': 'sharpen',
      'label': 'Sharpen',
      'category': 'Blur & Style',
      'params': [
        {
          'id': 'amount',
          'label': 'Amount',
          'type': 'float',
          'min': 0.0,
          'max': 1.0,
          'default': 0.3,
        },
      ],
    },
    {
      'id': 'blurIsland',
      'label': 'Blur Island',
      'category': 'Blur & Style',
      'params': [
        {
          'id': 'radius',
          'label': 'Radius',
          'type': 'float',
          'min': 0.0,
          'max': 100.0,
          'default': 24.0,
          'unit': 'px@1080',
        },
        {
          'id': 'centerX',
          'label': 'Center X',
          'type': 'float',
          'min': -1.0,
          'max': 1.0,
          'default': 0.0,
        },
        {
          'id': 'centerY',
          'label': 'Center Y',
          'type': 'float',
          'min': -1.0,
          'max': 1.0,
          'default': 0.0,
        },
        {
          'id': 'size',
          'label': 'Size',
          'type': 'float',
          'min': 0.0,
          'max': 1.0,
          'default': 0.4,
        },
        {
          'id': 'aspect',
          'label': 'Aspect',
          'type': 'float',
          'min': 0.1,
          'max': 4.0,
          'default': 1.0,
        },
        {
          'id': 'feather',
          'label': 'Feather',
          'type': 'float',
          'min': 0.0,
          'max': 1.0,
          'default': 0.4,
        },
      ],
    },
    {
      'id': 'crop',
      'label': 'Crop',
      'category': 'Transform',
      'params': [
        {
          'id': 'left',
          'label': 'Left',
          'type': 'float',
          'min': 0.0,
          'max': 100.0,
          'default': 0.0,
        },
        {
          'id': 'right',
          'label': 'Right',
          'type': 'float',
          'min': 0.0,
          'max': 100.0,
          'default': 0.0,
        },
        {
          'id': 'top',
          'label': 'Top',
          'type': 'float',
          'min': 0.0,
          'max': 100.0,
          'default': 0.0,
        },
        {
          'id': 'bottom',
          'label': 'Bottom',
          'type': 'float',
          'min': 0.0,
          'max': 100.0,
          'default': 0.0,
        },
        {
          'id': 'feather',
          'label': 'Feather',
          'type': 'float',
          'min': 0.0,
          'max': 100.0,
          'default': 0.0,
        },
        {
          'id': 'radius',
          'label': 'Corner Radius',
          'type': 'float',
          'min': 0.0,
          'max': 200.0,
          'default': 0.0,
        },
      ],
    },
    {
      'id': 'dropShadow',
      'label': 'Drop Shadow',
      'category': 'Transform',
      'params': [
        {
          'id': 'offsetX',
          'label': 'Offset X',
          'type': 'float',
          'min': -200.0,
          'max': 200.0,
          'default': 8.0,
        },
        {
          'id': 'offsetY',
          'label': 'Offset Y',
          'type': 'float',
          'min': -200.0,
          'max': 200.0,
          'default': 8.0,
        },
        {
          'id': 'blur',
          'label': 'Blur',
          'type': 'float',
          'min': 0.0,
          'max': 100.0,
          'default': 16.0,
        },
        {
          'id': 'color',
          'label': 'Color',
          'type': 'color',
          'static': true,
          'default': '#000000',
        },
        {
          'id': 'opacity',
          'label': 'Opacity',
          'type': 'float',
          'min': 0.0,
          'max': 1.0,
          'default': 0.6,
        },
      ],
    },
  ];

  Clip? _editableClip(String? clipId) {
    final clip = clipById(clipId);
    if (clip == null || _locked(clip.trackId)) return null;
    return clip;
  }

  Map<String, dynamic>? _effectDef(
    String typeId, {
    List<Map<String, dynamic>>? catalog,
  }) => (catalog ?? kFallbackEffectCatalog).firstWhereOrNull(
    (e) => e['id'] == typeId,
  );

  Map<String, dynamic>? _effectInstance(Clip clip, String instanceId) => clip
      .effects
      .whereType<Map<String, dynamic>>()
      .firstWhereOrNull((e) => e['id'] == instanceId);

  /// FX-2/FX-4: builds an instance from catalog defaults; color/enum params
  /// stay static-only.
  String addEffect(
    String clipId,
    String typeId, {
    bool onTop = false,
    List<Map<String, dynamic>>? catalog,
  }) {
    final clip = _editableClip(clipId);
    final def = _effectDef(typeId, catalog: catalog);
    if (clip == null || def == null) return '';
    final instance = <String, dynamic>{
      'id': generateId(),
      'type': typeId,
      'enabled': true,
      'params': {
        for (final p in (def['params'] as List? ?? const []))
          if (p is Map<String, dynamic> && p['id'] is String)
            p['id'] as String:
                ParamValue.fromJson({
                  'static': p['default'],
                  if (!(p['static'] == true ||
                      p['type'] == 'color' ||
                      p['type'] == 'enum'))
                    'keyframes': <Map<String, dynamic>>[],
                }).toJson(),
      },
    };
    _run('Add effect', (tx) {
      tx.clip(clipId);
      onTop ? clip.effects.insert(0, instance) : clip.effects.add(instance);
    });
    return instance['id'] as String;
  }

  void removeEffect(String clipId, String effectInstanceId) {
    final clip = _editableClip(clipId);
    if (clip == null || _effectInstance(clip, effectInstanceId) == null) return;
    _run('Remove effect', (tx) {
      tx.clip(clipId);
      clip.effects.removeWhere((e) => e is Map && e['id'] == effectInstanceId);
    });
  }

  /// FX-1: list order IS application order — index 0 applied first.
  void reorderEffect(String clipId, String effectInstanceId, int newIndex) {
    final clip = _editableClip(clipId);
    if (clip == null) return;
    final from = clip.effects.indexWhere(
      (e) => e is Map && e['id'] == effectInstanceId,
    );
    if (from < 0) return;
    final to = newIndex.clamp(0, clip.effects.length - 1);
    if (from == to) return;
    _run('Reorder effect', (tx) {
      tx.clip(clipId);
      final moved = clip.effects.removeAt(from);
      clip.effects.insert(to, moved);
    });
  }

  void setEffectEnabled(String clipId, String effectInstanceId, bool enabled) {
    final clip = _editableClip(clipId);
    final fx = clip == null ? null : _effectInstance(clip, effectInstanceId);
    if (fx == null || fx['enabled'] == enabled) return;
    _run('Toggle effect', (tx) {
      tx.clip(clipId);
      fx['enabled'] = enabled;
    });
  }

  /// Params back to catalog defaults as plain statics — keyframes included
  /// in the wipe, one undo step restores them.
  void resetEffect(
    String clipId,
    String effectInstanceId, {
    List<Map<String, dynamic>>? catalog,
  }) {
    final clip = _editableClip(clipId);
    final fx = clip == null ? null : _effectInstance(clip, effectInstanceId);
    if (fx == null) return;
    final def = _effectDef(fx['type'] as String? ?? '', catalog: catalog);
    if (def == null) return;
    _run('Reset effect', (tx) {
      tx.clip(clipId);
      final raw = fx['params'];
      final map = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
      for (final p in (def['params'] as List? ?? const [])) {
        if (p is! Map<String, dynamic> || p['id'] is! String) continue;
        map[p['id'] as String] =
            ParamValue.staticNum(
              (p['default'] as num?)?.toDouble() ?? 0,
            ).toJson();
      }
      fx['params'] = map;
    });
  }

  /// Sets the static value; keyframes keep animating until explicitly
  /// cleared (FX-4).
  void setEffectParam(
    String clipId,
    String effectInstanceId,
    String paramId,
    Object value,
  ) {
    final clip = _editableClip(clipId);
    final fx = clip == null ? null : _effectInstance(clip, effectInstanceId);
    final params = fx?['params'];
    if (params is! Map<String, dynamic>) return;
    _run('Set param', (tx) {
      tx.clip(clipId);
      final pv = ParamValue.from(params[paramId]);
      pv.static = value;
      params[paramId] = pv.toJson();
    });
  }

  // --- Keyframes (KEY-2/3/7) --------------------------------------------------

  /// Resolves the live params map for a pseudo-instance ('__transform') or
  /// real effect instance.
  Map<String, dynamic>? _paramsFor(Clip clip, String effectInstanceId) {
    if (effectInstanceId == '__transform') {
      clip.transform ??= ClipTransform();
      return null; // transform params are live ParamValues, see _paramFor
    }
    final params = _effectInstance(clip, effectInstanceId)?['params'];
    return params is Map<String, dynamic> ? params : null;
  }

  /// Read-modify-write on the stored param JSON: [mutate] edits a detached
  /// ParamValue and the result is written back so undo deltas observe the
  /// change (the map is the source of truth).
  void mutateParam(
    Clip clip,
    String effectInstanceId,
    String paramId,
    void Function(ParamValue pv) mutate,
  ) {
    if (effectInstanceId == '__transform') {
      clip.transform ??= ClipTransform();
      final pv = switch (paramId) {
        'x' => clip.transform!.x,
        'y' => clip.transform!.y,
        'scale' => clip.transform!.scale,
        'rotation' => clip.transform!.rotation,
        'anchor' => clip.transform!.anchor,
        'opacity' => clip.transform!.opacity,
        _ => null,
      };
      if (pv != null) mutate(pv);
      return;
    }
    final params = _paramsFor(clip, effectInstanceId);
    if (params == null) return;
    final pv = ParamValue.from(params[paramId]);
    mutate(pv);
    params[paramId] = pv.toJson();
  }

  /// KEY-3: the first-ever key seeds from the current static value; a second
  /// toggle at the same time removes the key again (◆ behaviour).
  void toggleKeyframe(
    String clipId,
    String effectInstanceId,
    String paramId,
    Rt t,
  ) {
    final clip = _editableClip(clipId);
    if (clip == null) return;
    _run('Toggle keyframe', (tx) {
      tx.clip(clipId);
      mutateParam(clip, effectInstanceId, paramId, (pv) {
        _toggleKeyOn(pv, t, clip.duration);
      });
    });
  }

  void _toggleKeyOn(ParamValue pv, Rt t, Rt clipDuration) {
    final time = t.clampTo(Rt.zero(), clipDuration);
    final hit = pv.keyframes.indexWhere(
      (k) =>
          (ParamValue.timeOf(k) - time).micros.abs() <=
          frameDuration.micros ~/ 2,
    );
    if (hit >= 0) {
      pv.keyframes.removeAt(hit);
      pv.sortKeys();
      return;
    }
    final value = pv.evaluate(time);
    if (!pv.animated) {
      // KEY-3: seed the span with the static value so nothing is lost.
      pv.keyframes.add({
        't': Rt.zero().toString(),
        'v': pv.static,
        'interp': 'linear',
      });
      // At clip start the seed is itself the requested key. A duplicate zero
      // key would violate the strictly-increasing model invariant.
      if (time.micros.abs() <= frameDuration.micros ~/ 2) {
        pv.sortKeys();
        return;
      }
    }
    pv.keyframes.add({'t': time.toString(), 'v': value, 'interp': 'linear'});
    pv.sortKeys();
  }

  void setKeyframeValue(
    String clipId,
    String effectInstanceId,
    String paramId,
    Rt t,
    Object value,
  ) {
    final clip = _editableClip(clipId);
    if (clip == null) return;
    _run('Set keyframe value', (tx) {
      tx.clip(clipId);
      mutateParam(clip, effectInstanceId, paramId, (pv) {
        final time = t.clampTo(Rt.zero(), clip.duration);
        if (!pv.animated) {
          pv.keyframes.add({
            't': Rt.zero().toString(),
            'v': pv.static,
            'interp': 'linear',
          });
        }
        final hit = pv.keyframes.indexWhere(
          (k) =>
              (ParamValue.timeOf(k) - time).micros.abs() <=
              frameDuration.micros ~/ 2,
        );
        if (hit >= 0) {
          pv.keyframes[hit]['v'] = value;
        } else {
          pv.keyframes.add({
            't': time.toString(),
            'v': value,
            'interp': 'linear',
          });
        }
        pv.sortKeys();
      });
    });
  }

  void removeKeyframe(
    String clipId,
    String effectInstanceId,
    String paramId,
    Rt t,
  ) {
    final clip = _editableClip(clipId);
    if (clip == null) return;
    _run('Remove keyframe', (tx) {
      tx.clip(clipId);
      mutateParam(clip, effectInstanceId, paramId, (pv) {
        final time = t.clampTo(Rt.zero(), clip.duration);
        pv.keyframes.removeWhere(
          (k) =>
              (ParamValue.timeOf(k) - time).micros.abs() <=
              frameDuration.micros ~/ 2,
        );
      });
    });
  }

  /// Acceptance criterion 3: clearing returns the LAST evaluated value to
  /// static mode; undo brings the keys back.
  void clearKeyframes(String clipId, String effectInstanceId, String paramId) {
    final clip = _editableClip(clipId);
    if (clip == null) return;
    _run('Clear keyframes', (tx) {
      tx.clip(clipId);
      mutateParam(clip, effectInstanceId, paramId, (pv) {
        if (!pv.animated) return;
        final last = pv.evaluate(clip.duration);
        pv.keyframes.clear();
        pv.static = last;
      });
    });
  }

  /// Moves a key to a new clip-local time clamped to [0, duration]; returns
  /// the applied time, or null when there was no key at [oldT].
  Rt? moveKeyframe(
    String clipId,
    String effectInstanceId,
    String paramId,
    Rt oldT,
    Rt newT,
  ) {
    final clip = _editableClip(clipId);
    if (clip == null) return null;
    final applied = newT.clampTo(Rt.zero(), clip.duration);
    Rt? result;
    _run('Move keyframe', (tx) {
      tx.clip(clipId);
      mutateParam(clip, effectInstanceId, paramId, (pv) {
        final from = oldT.clampTo(Rt.zero(), clip.duration);
        final hit = pv.keyframes.indexWhere(
          (k) =>
              (ParamValue.timeOf(k) - from).micros.abs() <=
              frameDuration.micros ~/ 2,
        );
        if (hit < 0) return;
        final moved = {...pv.keyframes[hit], 't': applied.toString()};
        pv.keyframes[hit] = moved;
        pv.sortKeys();
        result = applied;
      });
    });
    return result;
  }

  // --- Blending (FX-12) --------------------------------------------------------

  void setClipBlend(String clipId, String mode) {
    final clip = _editableClip(clipId);
    if (clip == null || clip.blend == mode) return;
    _run('Blend mode', (tx) {
      tx.clip(clipId);
      clip.blend = mode;
    });
  }

  // --- Transform edits (FX-9) ----------------------------------------------

  /// Edits the clip's built-in transform through [mutate]; creates the
  /// transform lazily so the first drag/toggle behaves like any other edit.
  void setClipTransform(
    String clipId,
    ClipTransform Function(ClipTransform t) mutate,
  ) {
    final clip = _editableClip(clipId);
    if (clip == null) return;
    _run('Transform', (tx) {
      tx.clip(clipId);
      clip.transform ??= ClipTransform();
      mutate(clip.transform!);
    });
  }

  /// Static parameters stay static; animated parameters create or replace a
  /// key at [at], so the value visible under the playhead is what changes.
  ///
  /// [rebase] is for direct manipulation (the on-canvas gizmo): on a clip with
  /// a generated image animation it moves the resting pose instead of writing
  /// a key that the next rebuild would discard.
  void setTransformParam(
    String clipId,
    String paramId,
    double value, {
    Rt? at,
    bool rebase = false,
  }) {
    final clip = _editableClip(clipId);
    if (clip == null) return;
    _run('Transform', (tx) {
      tx.clip(clipId);
      clip.transform ??= ClipTransform();
      final param = switch (paramId) {
        'x' => clip.transform!.x,
        'y' => clip.transform!.y,
        'scale' => clip.transform!.scale,
        'rotation' => clip.transform!.rotation,
        'anchor' => clip.transform!.anchor,
        'opacity' => clip.transform!.opacity,
        _ => null,
      };
      if (param == null) return;
      // A direct-manipulation drag on a clip whose animation is generated is
      // moving the *resting pose*: a raw keyframe here would be erased by the
      // next rebuild, so move the pose and replay the animation around it.
      if (rebase &&
          imageAnimSpec(clip) != null &&
          _animParams.contains(paramId)) {
        _syncAnimBase(clip, paramId, value);
        return;
      }
      final keyValue = paramId == 'anchor' ? {'x': value, 'y': 0.0} : value;
      if (!param.animated) {
        param.static = keyValue;
        return;
      }
      final time = (at ?? playhead.minus(clip.start)).clampTo(
        Rt.zero(),
        clip.duration,
      );
      final hit = param.keyframes.indexWhere(
        (key) =>
            (ParamValue.timeOf(key) - time).micros.abs() <=
            frameDuration.micros ~/ 2,
      );
      if (hit >= 0) {
        param.keyframes[hit]['v'] = keyValue;
      } else {
        param.keyframes.add({
          't': time.toString(),
          'v': keyValue,
          'interp': 'linear',
        });
      }
      param.sortKeys();
    });
  }

  // --- Paste settings (TIM-17 / FX-3) -------------------------------------------

  /// Snapshot of one clip's look and audio controls. Timing, speed, source
  /// range, links and text content deliberately remain destination-owned.
  Map<String, dynamic>? _attributeClipboard;

  bool get hasAttributeClipboard => _attributeClipboard != null;

  /// Whether at least one unlocked selected clip can receive something from
  /// the settings clipboard. Used to disable the context-menu action.
  bool get canPasteAttributes {
    final payload = _attributeClipboard;
    if (payload == null) return false;
    for (final clip in selectedClips) {
      if (_locked(clip.trackId)) continue;
      if (payload['visual'] == true && _isVisualClip(clip)) return true;
      if (payload['audio'] == true && _hasClipAudio(clip)) return true;
    }
    return false;
  }

  /// FX-14 data: >8 enabled effects on the selected clip shows a perf hint
  /// (never blocks).
  bool get selectionOverloaded {
    final clip = selectedClip;
    if (clip == null) return false;
    var n = 0;
    for (final e in clip.effects) {
      if (e is Map<String, dynamic> && e['enabled'] != false) n++;
    }
    return n > 8;
  }

  void copyAttributes() {
    final clip = selectedClip;
    if (clip == null) return;
    _copyAttributesFrom(clip);
    notifyListeners();
  }

  void _copyAttributesFrom(Clip clip) {
    _attributeClipboard = {
      'visual': _isVisualClip(clip),
      'audio': _hasClipAudio(clip),
      'blend': clip.blend,
      'transform': _cloneSettingValue(clip.transform?.toJson()),
      'effects': [
        for (final e in clip.effects)
          if (e is Map<String, dynamic>) _cloneSettingValue(e),
      ],
      'volume': clip.volume,
      'pan': clip.pan,
      'mute': clip.mute,
      'fadeIn': clip.fadeIn.toJson(),
      'fadeOut': clip.fadeOut.toJson(),
    };
  }

  dynamic _cloneSettingValue(dynamic value) {
    if (value is ParamValue) return _cloneSettingValue(value.toJson());
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _cloneSettingValue(entry.value),
      };
    }
    if (value is List) {
      return <dynamic>[for (final item in value) _cloneSettingValue(item)];
    }
    return value;
  }

  Map<String, dynamic> _effectSettingCopy(
    Map<String, dynamic> effect, {
    bool freshId = false,
  }) {
    final copy = _cloneSettingValue(effect) as Map<String, dynamic>;
    if (freshId) copy['id'] = generateId();
    return copy;
  }

  bool _isVisualClip(Clip clip) =>
      doc.trackById(clip.trackId)?.isVideo ?? false;

  bool _hasClipAudio(Clip clip) {
    if (clip.text != null) return false;
    return doc.assetById(clip.mediaId)?.hasAudio ?? false;
  }

  /// Pastes compatible settings onto the whole selection in one transaction.
  /// Effect stacks replace rather than merge, and receive fresh instance ids.
  void pasteAttributes({
    bool effects = true,
    bool transform = true,
    bool audio = true,
  }) {
    final payload = _attributeClipboard;
    if (payload == null) return;
    final targets = selectedClips.where((clip) {
      if (_locked(clip.trackId)) return false;
      return (payload['visual'] == true && _isVisualClip(clip)) ||
          (audio && payload['audio'] == true && _hasClipAudio(clip));
    }).toList();
    if (targets.isEmpty) return;
    _run('Paste settings', (tx) {
      for (final clip in targets) {
        tx.clip(clip.id);
        if (payload['visual'] == true && _isVisualClip(clip)) {
          if (payload['blend'] is String) {
            clip.blend = payload['blend'] as String;
          }
          if (transform) {
            final value = payload['transform'];
            clip.transform = value is Map<String, dynamic>
                ? ClipTransform.fromJson(
                    _cloneSettingValue(value) as Map<String, dynamic>,
                  )
                : null;
          }
          if (effects && payload['effects'] is List) {
            clip.effects
              ..clear()
              ..addAll([
                for (final e in (payload['effects'] as List))
                  if (e is Map<String, dynamic>)
                    _effectSettingCopy(e, freshId: true),
              ]);
          }
        }
        if (audio && payload['audio'] == true && _hasClipAudio(clip)) {
          if (payload['volume'] is num) {
            clip.volume = (payload['volume'] as num).toDouble();
          }
          if (payload['pan'] is num) {
            clip.pan = (payload['pan'] as num).toDouble();
          }
          if (payload['mute'] is bool) clip.mute = payload['mute'] as bool;
          final fadeIn = Fade.fromJson(
            payload['fadeIn'] as Map<String, dynamic>?,
          );
          final fadeOut = Fade.fromJson(
            payload['fadeOut'] as Map<String, dynamic>?,
          );
          final total = fadeIn.duration.plus(fadeOut.duration);
          if (total > clip.duration && total.micros > 0) {
            final inMicros =
                (clip.duration.micros * fadeIn.duration.micros /
                        total.micros)
                    .round();
            fadeIn.duration = Rt.fromMicros(inMicros);
            fadeOut.duration = clip.duration.minus(fadeIn.duration);
          }
          clip
            ..fadeIn = fadeIn
            ..fadeOut = fadeOut;
        }
      }
    });
  }

  // --- Media placement (TIM-5) ---------------------------------------------

  /// Puts an asset on the timeline. Video assets with sound also lay their
  /// audio onto the first free audio track and the two are linked, unless
  /// [linkAudioOnAdd] is off or [withAudio] overrides it for this call.
  List<String> placeAsset(
    String assetId, {
    String? trackId,
    Rt? at,
    DropMode mode = DropMode.append,
    bool? withAudio,
  }) {
    final placeAudio = withAudio ?? linkAudioOnAdd;
    final asset = doc.assetById(assetId);
    if (asset == null) return const [];
    var requested = trackById(trackId);
    // AUD-7: audio-only media dropped on the video area lands on an audio
    // track instead of refusing the drop.
    if (asset.type == 'audio' && (requested?.isVideo ?? false)) {
      requested = doc.audioTrack();
    }
    final videoTarget =
        requested ??
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
      final group =
          (asset.type == 'video' && asset.hasAudio && placeAudio)
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
        tx.clip(clip.id); // null "before" so undo deletes it
        doc.clips.add(clip);
        created.add(clip.id);
        return clip;
      }

      place(videoTarget);
      if (group != null) {
        final audioTrack =
            doc.audioTracks.firstOrNull ?? _createTrack(tx, 'audio');
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
    final times = doc.markers
        .map((m) => m.time)
        .sorted((a, b) => a.compareTo(b));
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
