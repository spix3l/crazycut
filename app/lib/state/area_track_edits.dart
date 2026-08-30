import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:crazycut_app/data/area_track.dart';
import 'package:crazycut_app/data/param_value.dart';
import 'package:crazycut_app/data/project.dart';
import 'package:crazycut_app/models/rational.dart';
import 'package:crazycut_app/state/canvas_geometry.dart';
import 'package:crazycut_app/state/commands.dart';
import 'package:crazycut_app/state/timeline_edits.dart';

/// Area-tracking operations (**TRK**).
///
/// Split from [TimelineEdits] the way [AudioEdits] is: that mixin is about
/// timeline geometry, this is about solved motion and what follows it. Every
/// operation here runs through the same command stack, so installing a solve,
/// pinning a clip and unpinning it are each a single undo step (**TRK-15**).
///
/// The pin is a *generated* spec, exactly like `extra.clipAnim` (**TXT-10**):
/// nothing derives a pose at render time, and `transform.corners` is rebuilt
/// from scratch whenever the tracker, the pin or the overlay's own geometry
/// changes. That is what keeps preview and export identical by construction —
/// both read the same baked quad out of the document.
mixin AreaTrackEdits on TimelineEdits {
  Clip? gizmoClipUnderPlayhead();
  Rt clipLocalTime(Clip clip);
  // Canvas geometry lives on EditorController, which is where all these mixins
  // are combined. Declaring them here rather than widening the `on` clause
  // keeps the dependency one-way: this mixin needs the geometry, the controller
  // supplies it, and neither file has to import the other.
  (int, int)? gizmoSourceSize(Clip clip);
  Rect? clipRectInSequence(Clip clip);
  double clipRotation(Clip clip);

  /// Below this the generated corner keyframes are dropped: a pin that never
  /// moves is better expressed as the clip's own static pose.
  static const double kStaticQuadEpsilon = 0.01;

  // --- Tool state and entry points -----------------------------------------

  bool _trackToolActive = false;
  String? _trackRejection;

  /// Why the last attempt to track a region was refused, or null.
  ///
  /// Refusals used to be a silent `return null`: the user dragged a box, let
  /// go, and nothing whatsoever happened. Anything that declines to solve now
  /// says so here and the Track tab shows it.
  String? get trackRejection => _trackRejection;

  void clearTrackRejection() {
    if (_trackRejection == null) return;
    _trackRejection = null;
    notifyListeners();
  }

  /// Surfaces a problem with a tracking action in the Track tab. Public so the
  /// inspector can report failures that happen outside this mixin.
  void reportTrackProblem(String why) => _reject(why);

  void _reject(String why) {
    _trackRejection = why;
    notifyListeners();
  }

  /// Whether the canvas region tool is armed (**TRK-1**). Mutually exclusive
  /// with the transform gizmo: only one tool owns the canvas at a time.
  bool get trackToolActive => _trackToolActive;

  set trackToolActive(bool value) {
    if (_trackToolActive == value) return;
    _trackToolActive = value;
    notifyListeners();
  }

  /// The clip the region tool acts on: the selected visual clip under the
  /// playhead, which is the same rule the gizmo uses.
  Clip? trackToolClip() => gizmoClipUnderPlayhead();

  /// The tracker solved against [clip], if any. One per clip in v1.
  Tracker? trackerForClip(Clip clip) {
    final own = doc.trackersForClip(clip.id);
    if (own.isNotEmpty) return own.first;
    // A pinned overlay shows the region it follows, not nothing.
    final pin = TrackPin.fromExtra(clip.extra);
    return pin == null ? null : doc.trackerById(pin.trackerId);
  }

  /// Solves [regionInSequence] on [clip] and installs the result.
  ///
  /// The region arrives in sequence px because that is what the canvas knows;
  /// it is converted into the clip's source px here, so the stored path is
  /// independent of sequence resolution and of the clip's own transform
  /// (**TRK-2**).
  /// [start] defaults to the frame the user is looking at, because that is the
  /// frame they drew the region on. Anchoring it at the clip's start instead
  /// positions the box for one frame and solves from another, which is wrong
  /// from the very first sample — and looks exactly like a tracker that cannot
  /// follow anything.
  Future<Tracker?> trackRegion(
    Clip clip,
    Quad regionInSequence, {
    Rt? start,
    Rt? end,
  }) async {
    _trackRejection = null;
    final from = start ?? clipLocalTime(clip);
    final asset = doc.assetById(clip.mediaId);
    if (asset == null) {
      _reject('That clip has no media to track.');
      return null;
    }
    final source = sequenceQuadToSource(clip, regionInSequence, from);
    if (source == null) {
      _reject(
        'That clip has not been probed yet, so there is nothing to measure '
        'the region against.',
      );
      return null;
    }
    final why = _regionRefusal(source, clip);
    if (why != null) {
      _reject(why);
      return null;
    }

    final tracker = await solveTrackedRegion(
      trackerId: trackerForClip(clip)?.id ?? generateId(),
      clip: clip,
      asset: asset,
      searchQuad: source,
      start: from,
      end: end ?? clip.duration,
    );
    if (tracker != null) {
      installTracker(tracker);
      // Drawing is done; staying armed would leave grab handles over the result
      // and keep the region tool eating pointers on the monitor. The outline
      // stays visible either way — it just stops being a control.
      trackToolActive = false;
    }
    return tracker;
  }

  /// Corrects the region at the playhead and re-solves forward from there,
  /// keeping the samples before it (**TRK-11**). One undo step.
  Future<Tracker?> retrackFromPlayhead(Clip clip, Quad regionInSequence) async {
    _trackRejection = null;
    final existing = trackerForClip(clip);
    final asset = doc.assetById(clip.mediaId);
    if (asset == null) return null;
    final at = clipLocalTime(clip);
    final source = sequenceQuadToSource(clip, regionInSequence, at);
    if (source == null) return null;
    final why = _regionRefusal(source, clip);
    if (why != null) {
      _reject(why);
      return null;
    }

    final solved = await solveTrackedRegion(
      trackerId: existing?.id ?? generateId(),
      clip: clip,
      asset: asset,
      searchQuad: source,
      start: at,
      end: existing?.endTime ?? clip.duration,
    );
    if (solved == null) return null;

    // Splice: everything the old solve knew before this frame is still good.
    final merged = existing == null || at <= existing.startTime
        ? solved
        : _spliceAt(existing, solved, at);
    installTracker(merged);
    return merged;
  }

  /// Keeps [before]'s samples up to [at] and takes [after]'s from there on.
  /// Only possible when the two share a sample rate, which they do because the
  /// re-solve is asked for the same rate; otherwise the new solve wins whole.
  Tracker _spliceAt(Tracker before, Tracker after, Rt at) {
    if (before.fps != after.fps) return after;
    final keep = before.sampleIndexAt(at);
    if (keep <= 0) return after;
    return before.copyWith(
      endTime: after.endTime,
      searchQuad: after.searchQuad,
      path: [...before.path.take(keep * 8), ...after.path],
      confidence: [...before.confidence.take(keep), ...after.confidence],
    );
  }

  /// **TRK-4**: too small, or off the frame, is refused rather than solved —
  /// and says which, because a refusal the user cannot see is the same to them
  /// as a feature that does not work.
  String? _regionRefusal(Quad source, Clip clip) {
    final size = gizmoSourceSize(clip);
    if (size == null) return 'That clip has no measured size yet.';
    if (!quadIsUsable(source)) return 'That region is not a usable shape.';
    var minX = source[0], maxX = source[0], minY = source[1], maxY = source[1];
    for (var i = 1; i < 4; i += 1) {
      minX = math.min(minX, source[2 * i]);
      maxX = math.max(maxX, source[2 * i]);
      minY = math.min(minY, source[2 * i + 1]);
      maxY = math.max(maxY, source[2 * i + 1]);
    }
    if (maxX - minX < 16 || maxY - minY < 16) {
      return 'That region is too small to track. Draw a bigger box.';
    }
    if (minX < 0 || minY < 0 || maxX > size.$1 || maxY > size.$2) {
      return 'That region falls outside the picture. Keep the box inside the '
          'frame.';
    }
    return null;
  }

  /// Runs the solve. Overridden in tests, and by the controller to route
  /// through [TrackingService]; the default refuses rather than pretending.
  Future<Tracker?> solveTrackedRegion({
    required String trackerId,
    required Clip clip,
    required MediaAsset asset,
    required Quad searchQuad,
    required Rt start,
    required Rt end,
  }) async => null;

  /// Sequence px back into the tracked clip's source px — the inverse of
  /// [_mapSourceQuad], and what turns a drawn rectangle into a stored region.
  Quad? sequenceQuadToSource(Clip clip, Quad quad, Rt local) {
    final size = gizmoSourceSize(clip);
    final rect = _rectAt(clip, local);
    if (size == null || rect == null || rect.width <= 0 || rect.height <= 0) {
      return null;
    }
    final rotation = _rotationAt(clip, local);
    final centre = rect.center;
    final out = <double>[];
    for (var i = 0; i < 4; i += 1) {
      var p = Offset(quad[2 * i], quad[2 * i + 1]);
      if (rotation != 0) p = rotatePoint(p, centre, -rotation);
      out
        ..add((p.dx - rect.left) / rect.width * size.$1)
        ..add((p.dy - rect.top) / rect.height * size.$2);
    }
    return out;
  }

  /// Clip-local `(start, end)` seconds where the solve behind [clip] fell below
  /// [threshold], clamped to the clip and ready for the timeline's stripe
  /// (**TRK-8**).
  ///
  /// Reported for the clip that was *tracked* and for anything pinned to it, so
  /// the warning appears wherever the user is looking when it matters.
  List<(double, double)> lowConfidenceSpansFor(
    Clip clip, {
    double threshold = 0.4,
  }) {
    final tracker = trackerForClip(clip);
    if (tracker == null) return const [];
    final source = doc.clipById(tracker.sourceClipId);
    if (source == null) return const [];

    final spans = <(double, double)>[];
    for (final span in tracker.lowConfidenceSpans(threshold: threshold)) {
      // Tracker times are local to the tracked clip; a pinned overlay may start
      // anywhere, so go through sequence time rather than assuming they align.
      final start = source.start + span.start - clip.start;
      final end = source.start + span.end - clip.start;
      final clampedStart = start.clampTo(Rt.zero(), clip.duration);
      final clampedEnd = end.clampTo(Rt.zero(), clip.duration);
      if (clampedEnd <= clampedStart) continue;
      spans.add((clampedStart.seconds, clampedEnd.seconds));
    }
    return spans;
  }

  // --- Trackers -------------------------------------------------------------

  /// Installs a solved path, replacing any earlier solve with the same id, and
  /// rebuilds every clip pinned to it. One undo step, whole path included.
  void installTracker(Tracker tracker) {
    runEdit('Track region', (tx) {
      tx.tracker(tracker.id);
      final at = doc.trackers.indexWhere((t) => t.id == tracker.id);
      if (at >= 0) {
        doc.trackers[at] = tracker;
      } else {
        doc.trackers.add(tracker);
      }
      _rebuildPinsFor(tx, tracker.id);
    });
  }

  /// Removes a tracker and unpins everything that followed it (**TRK-22**).
  void deleteTracker(String trackerId) {
    if (doc.trackerById(trackerId) == null) return;
    runEdit('Delete tracker', (tx) {
      for (final clip in _clipsPinnedTo(trackerId)) {
        tx.clip(clip.id);
        _clearPin(clip);
      }
      tx.tracker(trackerId);
      doc.trackers.removeWhere((t) => t.id == trackerId);
    });
  }

  List<Clip> _clipsPinnedTo(String trackerId) => [
    for (final clip in doc.clips)
      if (TrackPin.fromExtra(clip.extra)?.trackerId == trackerId) clip,
  ];

  /// Puts [assetId] on the tracked region and pins it — the whole point of the
  /// feature in one action (**TRK-18**).
  ///
  /// Before this existed, replacing a face meant importing the image, finding a
  /// track above the shot, dragging the clip out to the right range, selecting
  /// it, opening its Track tab and pinning it to a tracker named after some
  /// other clip. Six steps to express "put this here".
  ///
  /// The overlay is created on the first video track above the tracked clip,
  /// spanning exactly the solved range, and pinned corner-pin. One undo step.
  /// Returns the new clip's id.
  String? replaceRegionWithAsset({
    required String trackerId,
    required String assetId,
  }) {
    final tracker = doc.trackerById(trackerId);
    final asset = doc.assetById(assetId);
    final source = tracker == null ? null : doc.clipById(tracker.sourceClipId);
    if (tracker == null || asset == null || source == null) return null;

    final sourceTrack = doc.trackById(source.trackId);
    if (sourceTrack == null) return null;

    final start = source.start + tracker.startTime;
    final duration = tracker.endTime - tracker.startTime;
    if (duration <= Rt.zero()) return null;

    return runEdit('Replace tracked region', (tx) {
      final track = _trackAbove(tx, sourceTrack, start, start + duration);
      final clip = Clip(
        id: generateId(),
        trackId: track.id,
        mediaId: assetId,
        label: asset.name,
        start: start,
        duration: duration,
        sourceIn: Rt.zero(),
      );
      tx.clip(clip.id); // null "before", so undo deletes it
      doc.clips.add(clip);

      clip.extra[kTrackPinKey] =
          TrackPin(trackerId: trackerId, mode: PinMode.cornerPin).toJson();
      _rebuildPin(clip);

      selection
        ..clear()
        ..add(clip.id);
      return clip.id;
    });
  }

  /// The nearest video track above [below] that is free across the range, or a
  /// new one. Reusing a free track keeps a project from growing a track per
  /// tracked region, which is what "always add one" would do.
  Track _trackAbove(EditTransaction tx, Track below, Rt start, Rt end) {
    for (final track in doc.videoTracks) {
      if (track.index <= below.index || track.lock) continue;
      final busy = doc
          .clipsOn(track.id)
          .any((c) => c.start < end && start < c.end);
      if (!busy) return track;
    }
    return addTrackIn(tx, 'video');
  }

  // --- Pinning --------------------------------------------------------------

  /// Pins [clipId] to [trackerId].
  ///
  /// Pinning *moves* the overlay onto the region — in `cornerPin` it adopts the
  /// region's quad outright, which is the whole point of dropping an image onto
  /// a face. A subsequent nudge is kept on the pin and survives a re-solve
  /// (**TRK-19**).
  void pinClipToTracker(
    String clipId,
    String trackerId, {
    PinMode mode = PinMode.cornerPin,
  }) {
    final clip = doc.clipById(clipId);
    final tracker = doc.trackerById(trackerId);
    if (clip == null || tracker == null) return;

    runEdit('Pin to tracker', (tx) {
      tx.clip(clipId);
      clip.extra[kTrackPinKey] =
          TrackPin(trackerId: trackerId, mode: mode).toJson();
      _rebuildPin(clip);
    });
  }

  void setPinMode(String clipId, PinMode mode) {
    final clip = doc.clipById(clipId);
    final pin = clip == null ? null : TrackPin.fromExtra(clip.extra);
    if (clip == null || pin == null || pin.mode == mode) return;
    if (doc.trackerById(pin.trackerId) == null) return;
    runEdit('Pin mode', (tx) {
      tx.clip(clipId);
      clip.extra[kTrackPinKey] = pin.copyWith(mode: mode).toJson();
      _rebuildPin(clip);
    });
  }

  /// Shifts a pinned overlay away from the tracked region. The nudge is stored
  /// on the pin, so it survives a re-solve rather than being flattened into the
  /// generated keyframes (**TRK-19**).
  void nudgePin(String clipId, Offset delta) {
    final clip = doc.clipById(clipId);
    final pin = clip == null ? null : TrackPin.fromExtra(clip.extra);
    if (clip == null || pin == null) return;
    runEdit('Nudge pinned overlay', (tx) {
      tx.clip(clipId);
      final moved = <double>[
        for (var i = 0; i < 4; i += 1) ...[
          pin.offset[2 * i] + delta.dx,
          pin.offset[2 * i + 1] + delta.dy,
        ],
      ];
      clip.extra[kTrackPinKey] = pin.copyWith(offset: moved).toJson();
      _rebuildPin(clip);
    });
  }

  /// Drops the pin and the pose it generated, leaving the clip where it was
  /// before it was pinned.
  void unpinClip(String clipId) {
    final clip = doc.clipById(clipId);
    if (clip == null || !clip.extra.containsKey(kTrackPinKey)) return;
    runEdit('Unpin from tracker', (tx) {
      tx.clip(clipId);
      _clearPin(clip);
    });
  }

  /// Keeps the generated corner keyframes and drops the pin, so the user can
  /// leave the tracking system entirely and hand-edit the result (**TRK-21**).
  void bakePinToKeyframes(String clipId) {
    final clip = doc.clipById(clipId);
    if (clip == null || !clip.extra.containsKey(kTrackPinKey)) return;
    runEdit('Bake tracked motion', (tx) {
      tx.clip(clipId);
      _rebuildPin(clip);
      clip.extra.remove(kTrackPinKey);
    });
  }

  void _clearPin(Clip clip) {
    clip.extra.remove(kTrackPinKey);
    clip.transform?.corners = null;
  }

  void _rebuildPinsFor(EditTransaction tx, String trackerId) {
    for (final clip in _clipsPinnedTo(trackerId)) {
      tx.clip(clip.id);
      _rebuildPin(clip);
    }
  }

  /// Rebuilds every pinned clip — after a sequence resize, or a change to a
  /// tracked clip's own transform, both of which move where a source pixel
  /// lands on the canvas.
  void rebuildAllPins() {
    final pinned = [
      for (final clip in doc.clips)
        if (clip.extra.containsKey(kTrackPinKey)) clip,
    ];
    if (pinned.isEmpty) return;
    runEdit('Update tracked overlays', (tx) {
      for (final clip in pinned) {
        tx.clip(clip.id);
        _rebuildPin(clip);
      }
    });
  }

  // --- Generation -----------------------------------------------------------

  /// Writes `transform.corners` for a pinned clip from its tracker.
  ///
  /// Rebuilt from scratch every time, never patched: the same rule `clipAnim`
  /// follows, and the reason a re-solve cannot leave stale keys behind.
  void _rebuildPin(Clip clip) {
    final pin = TrackPin.fromExtra(clip.extra);
    final tracker = pin == null ? null : doc.trackerById(pin.trackerId);
    final source = tracker == null ? null : doc.clipById(tracker.sourceClipId);
    if (pin == null || tracker == null || source == null) {
      clip.transform?.corners = null;
      return;
    }

    final quads = trackedQuadsInSequence(tracker, source);
    if (quads.isEmpty) {
      clip.transform?.corners = null;
      return;
    }

    // The overlay's own pose is the shape the simpler pin modes keep.
    final base = clipRectInSequence(clip);
    final baseQuad = base == null
        ? null
        : quadFromRotatedRect(base, rotationDegrees: clipRotation(clip));

    final keys = <Map<String, dynamic>>[];
    for (final entry in quads) {
      // Tracker times are local to the *tracked* clip; the overlay may start
      // anywhere. Go through sequence time rather than assuming they align.
      final sequenceTime = source.start + entry.local;
      final overlayLocal = sequenceTime - clip.start;
      if (overlayLocal < Rt.zero() || overlayLocal > clip.duration) continue;
      final posed = _poseFor(pin, entry.quad, baseQuad);
      keys.add({
        't': overlayLocal.toString(),
        'v': [
          for (var i = 0; i < 8; i += 1)
            posed[i] + pin.offset[i % 8],
        ],
        'interp': 'linear',
      });
    }

    if (keys.isEmpty) {
      clip.transform?.corners = null;
      return;
    }

    final transform = clip.transformOrDefault;
    clip.transform = transform;
    final first = (keys.first['v'] as List).cast<double>();
    final moves = keys.any(
      (k) => _quadDiffers((k['v'] as List).cast<double>(), first),
    );
    transform.corners = moves
        ? ParamValue(static: first, keyframes: keys)
        // A pin that never moves needs no keyframe track; one static quad says
        // the same thing and costs nothing to evaluate.
        : ParamValue.quad(first);
  }

  bool _quadDiffers(List<double> a, List<double> b) {
    for (var i = 0; i < 8; i += 1) {
      if ((a[i] - b[i]).abs() > kStaticQuadEpsilon) return true;
    }
    return false;
  }

  /// The quad an overlay takes in a given pin mode.
  ///
  /// All four modes emit a quad, so the compositor has one path. The simpler
  /// modes keep the overlay's own shape and borrow only part of the solve —
  /// which is what makes a jittery track usable in `positionScale` when it is
  /// not in `cornerPin` (**TRK-18**).
  Quad _poseFor(TrackPin pin, Quad tracked, Quad? base) {
    if (pin.mode == PinMode.cornerPin || base == null) return tracked;

    final centre = quadCentre(tracked);
    final baseCentre = quadCentre(base);
    final baseArea = quadTwiceArea(base).abs();
    final trackedArea = quadTwiceArea(tracked).abs();

    var scale = 1.0;
    if (pin.mode != PinMode.position && baseArea > 0 && trackedArea > 0) {
      scale = math.sqrt(trackedArea / baseArea);
    }

    var rotation = 0.0;
    if (pin.mode == PinMode.positionScaleRotation) {
      // Roll is the angle of the tracked quad's top edge, relative to the
      // overlay's own top edge.
      rotation = _edgeAngle(tracked) - _edgeAngle(base);
    }

    final cos = math.cos(rotation), sin = math.sin(rotation);
    return [
      for (var i = 0; i < 4; i += 1) ...[
        () {
          final dx = (base[2 * i] - baseCentre.x) * scale;
          final dy = (base[2 * i + 1] - baseCentre.y) * scale;
          return centre.x + dx * cos - dy * sin;
        }(),
        () {
          final dx = (base[2 * i] - baseCentre.x) * scale;
          final dy = (base[2 * i + 1] - baseCentre.y) * scale;
          return centre.y + dx * sin + dy * cos;
        }(),
      ],
    ];
  }

  double _edgeAngle(Quad q) => math.atan2(q[3] - q[1], q[2] - q[0]);

  // --- Source px → sequence px ----------------------------------------------

  /// Every solved sample of [tracker], mapped onto the sequence canvas.
  List<({Rt local, Quad quad})> trackedQuadsInSequence(
    Tracker tracker,
    Clip source,
  ) {
    final out = <({Rt local, Quad quad})>[];
    final step = tracker.fps.seconds <= 0 ? 0.0 : 1.0 / tracker.fps.seconds;
    if (step <= 0) return out;
    for (var i = 0; i < tracker.sampleCount; i += 1) {
      final local = tracker.startTime + Rt.fromSeconds(i * step);
      final quad = _mapSourceQuad(source, tracker.sample(i), local);
      if (quad != null) out.add((local: local, quad: quad));
    }
    return out;
  }

  /// The tracked quad at one clip-local time, on the sequence canvas.
  Quad? trackedQuadInSequence(Tracker tracker, Clip source, Rt local) =>
      _mapSourceQuad(source, tracker.quadAt(local), local);

  /// Maps a quad in the tracked clip's *source* pixels onto the sequence
  /// canvas, through that clip's own framing, transform and rotation.
  ///
  /// This is the step that makes tracking independent of how the tracked clip
  /// is presented: scale the footage down and the pinned overlay follows it
  /// down, because both go through the same placement.
  Quad? _mapSourceQuad(Clip source, Quad quad, Rt local) {
    final size = gizmoSourceSize(source);
    final rect = _rectAt(source, local);
    if (size == null || rect == null || size.$1 <= 0 || size.$2 <= 0) {
      return null;
    }
    final rotation = _rotationAt(source, local);
    final centre = rect.center;
    final out = <double>[];
    for (var i = 0; i < 4; i += 1) {
      var p = Offset(
        rect.left + quad[2 * i] / size.$1 * rect.width,
        rect.top + quad[2 * i + 1] / size.$2 * rect.height,
      );
      if (rotation != 0) p = rotatePoint(p, centre, rotation);
      out
        ..add(p.dx)
        ..add(p.dy);
    }
    return out;
  }

  /// [clipRectInSequence] evaluated at an arbitrary clip-local time rather than
  /// the playhead — a tracked clip's own transform may itself be animated.
  Rect? _rectAt(Clip clip, Rt local) {
    final size = gizmoSourceSize(clip);
    if (size == null) return null;
    final t = clip.transformOrDefault;
    final at = local.clampTo(Rt.zero(), clip.duration);
    double evalNum(ParamValue p, double fallback) {
      final v = p.evaluate(at);
      return v is num ? v.toDouble() : fallback;
    }

    final anchor = t.anchor.evaluate(at);
    double axis(String key) => anchor is Map && anchor[key] is num
        ? (anchor[key] as num).toDouble()
        : 0;

    return layerRectInSequence(
      seqW: doc.settings.width,
      seqH: doc.settings.height,
      srcW: size.$1,
      srcH: size.$2,
      framing: clip.text != null ? 'native' : t.framing,
      x: evalNum(t.x, 0),
      y: evalNum(t.y, 0),
      scalePercent: evalNum(t.scale, 100),
      anchorX: axis('x'),
      anchorY: axis('y'),
    );
  }

  double _rotationAt(Clip clip, Rt local) {
    final v = clip.transformOrDefault.rotation.evaluate(
      local.clampTo(Rt.zero(), clip.duration),
    );
    return v is num ? v.toDouble() : 0;
  }
}
