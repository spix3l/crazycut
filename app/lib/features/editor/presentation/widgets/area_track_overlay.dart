import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart' hide Clip;

import '../../../../core/design/tokens.dart';
import '../../../../data/area_track.dart';
import '../../../../data/project.dart';
import '../../../../models/rational.dart';
import '../../../../state/canvas_geometry.dart';
import '../../../../state/editor_controller.dart';
import '../../../../state/tracking_service.dart';

/// On-canvas region tool and tracked-region readout (**TRK-1/2**).
///
/// Three states, and the middle one is the one that makes the feature legible:
///
/// - **Armed, nothing solved.** Press, drag, release to draw the region.
/// - **Solved, tool disarmed.** The tracked quad is drawn following the region
///   as the playhead moves, without handles. This is what shows a track is
///   working *before* any image is attached to it — the outline moving with the
///   subject is the whole evidence that the solve is good.
/// - **Solved, tool armed.** As above with draggable corners, so a frame can be
///   corrected and re-tracked forward from there (**TRK-11**).
///
/// The playhead is published on its own throttled channel rather than through
/// the controller's listeners, so this widget watches `playheadNotifier`
/// directly. Without that the outline simply does not follow a scrub.
///
/// The pan recognizer is gated exactly like [CanvasGizmo]'s: it only competes
/// for pointers that land on the tool, so the monitor keeps the gestures it had
/// before this was layered on top. A tool that grabbed every pointer would take
/// double-tap-to-edit-text with it.
class AreaTrackOverlay extends StatefulWidget {
  const AreaTrackOverlay({super.key, required this.controller});

  final EditorController controller;

  @override
  State<AreaTrackOverlay> createState() => _AreaTrackOverlayState();
}

class _AreaTrackOverlayState extends State<AreaTrackOverlay> {
  static const double _handleSize = 9;
  static const double _hitSlop = 12;

  /// Below this the drag is a click, not a region (**TRK-4** rejects tiny
  /// regions outright; this stops one being *created* by a stray click).
  static const double _minDragPx = 8;

  EditorController get c => widget.controller;

  Offset? _dragStart;
  Offset? _dragNow;
  int _corner = -1;
  Quad? _editing;

  /// The box the user drew, kept on screen until the solve it started resolves.
  ///
  /// Clearing it on pointer-up made a solve look like nothing had happened: the
  /// rectangle vanished and, for the seconds before the first result, there was
  /// no evidence the tool had done anything at all.
  Quad? _pending;

  double _seqPerPx(Size box) =>
      box.width <= 0 ? 1 : c.doc.settings.width / box.width;

  /// The clip whose region this draws: the one the tool would act on, or —
  /// when a pinned overlay is selected — the clip its tracker was solved
  /// against, so selecting the meme image still shows the region it sits on.
  Clip? get _clip {
    final clip = c.trackToolClip();
    if (clip == null) return null;
    final pin = TrackPin.fromExtra(clip.extra);
    if (pin == null) return clip;
    final tracker = c.doc.trackerById(pin.trackerId);
    return tracker == null ? clip : (c.doc.clipById(tracker.sourceClipId) ?? clip);
  }

  Tracker? get _tracker {
    final clip = _clip;
    return clip == null ? null : c.trackerForClip(clip);
  }

  /// The tracked quad at the playhead, in sequence px, or null when there is
  /// no solve yet.
  Quad? _quadSeq() {
    final clip = _clip;
    final tracker = _tracker;
    if (clip == null || tracker == null) return null;
    return c.trackedQuadInSequence(tracker, clip, c.clipLocalTime(clip));
  }

  Offset _toSeq(Offset local, Size box) => local * _seqPerPx(box);
  Offset _toPx(Offset seq, Size box) => seq / _seqPerPx(box);

  int _cornerAt(Offset local, Size box, Quad quad) {
    for (var i = 0; i < 4; i += 1) {
      final at = _toPx(Offset(quad[2 * i], quad[2 * i + 1]), box);
      if ((at - local).distance <= _hitSlop) return i;
    }
    return -1;
  }

  bool _onPointerDown(Offset local, Size box) {
    final quad = _editing ?? _quadSeq();
    if (quad != null) {
      final corner = _cornerAt(local, box, quad);
      if (corner >= 0) {
        setState(() {
          _corner = corner;
          _editing = [...quad];
        });
        return true;
      }
      // Dragging inside an existing quad moves the whole region.
      if (quadContains(quad, _toSeq(local, box))) {
        setState(() {
          _corner = 4; // "all corners"
          _editing = [...quad];
          _dragStart = local;
        });
        return true;
      }
    }
    // Otherwise start drawing a fresh rectangle.
    setState(() {
      _corner = -1;
      _editing = null;
      _dragStart = local;
      _dragNow = local;
    });
    return true;
  }

  void _onPanUpdate(Offset local, Size box) {
    final editing = _editing;
    if (editing != null && _corner >= 0) {
      setState(() {
        if (_corner == 4) {
          final from = _dragStart;
          if (from == null) return;
          final delta = _toSeq(local - from, box);
          _editing = [
            for (var i = 0; i < 4; i += 1) ...[
              editing[2 * i] + delta.dx,
              editing[2 * i + 1] + delta.dy,
            ],
          ];
          _dragStart = local;
        } else {
          final seq = _toSeq(local, box);
          _editing = [...editing]
            ..[_corner * 2] = seq.dx
            ..[_corner * 2 + 1] = seq.dy;
        }
      });
      return;
    }
    setState(() => _dragNow = local);
  }

  void _onPanEnd(Size box) {
    final clip = _clip;
    if (clip == null) {
      _reset();
      return;
    }

    final editing = _editing;
    if (editing != null && _corner >= 0) {
      // A corrected quad re-solves forward from this frame (TRK-11).
      c.retrackFromPlayhead(clip, editing);
      _reset();
      return;
    }

    final from = _dragStart;
    final to = _dragNow;
    if (from == null || to == null || (to - from).distance < _minDragPx) {
      _reset();
      return;
    }
    final a = _toSeq(from, box);
    final b = _toSeq(to, box);
    final region = quadFromRect(
      left: a.dx < b.dx ? a.dx : b.dx,
      top: a.dy < b.dy ? a.dy : b.dy,
      right: a.dx < b.dx ? b.dx : a.dx,
      bottom: a.dy < b.dy ? b.dy : a.dy,
    );
    _reset();
    setState(() => _pending = region);
    // Not awaited for its value — the result installs itself — but the pending
    // box has to come down either way, including when the solve is refused.
    c.trackRegion(clip, region).whenComplete(() {
      if (mounted) setState(() => _pending = null);
    });
  }

  void _reset() => setState(() {
    _dragStart = null;
    _dragNow = null;
    _corner = -1;
    _editing = null;
  });

  @override
  Widget build(BuildContext context) {
    // Handles over moving frames are noise and would fight the transport for
    // the pointer, but the outline itself is worth keeping during playback:
    // watching it stay on the subject is how you judge a track.
    final clip = _clip;
    if (clip == null) return const SizedBox.shrink();
    final hasTracker = c.trackerForClip(clip) != null;
    if (!c.trackToolActive && !hasTracker) return const SizedBox.shrink();

    // Two channels the monitor does not otherwise rebuild on: the solve's
    // progress, and the playhead — which is published on its own throttled
    // notifier so a scrub does not rebuild the whole editor. Without the
    // second, the outline never moved.
    return ListenableBuilder(
      listenable: TrackingService.instance,
      builder: (context, _) => ValueListenableBuilder<Rt>(
        valueListenable: c.playheadNotifier,
        builder: (context, _, _) => _buildTool(),
      ),
    );
  }

  Widget _buildTool() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        final seqPerPx = _seqPerPx(box);
        final quad = _editing ?? _pending ?? _quadSeq();
        final solving =
            TrackingService.instance.jobForClip(_clip!.id)?.state ==
            TrackingState.running;
        // Handles are for editing; the outline is for reading. Showing grab
        // points while the tool is disarmed would advertise an interaction
        // that is not listening.
        final interactive = c.trackToolActive && !c.playing && !solving;

        Rect? drawing;
        final from = _dragStart;
        final to = _dragNow;
        if (_corner < 0 && from != null && to != null) {
          drawing = Rect.fromPoints(from, to);
        }

        final painter = _AreaTrackPainter(
          quad: quad,
          drawing: drawing,
          trail: _trail(),
          seqPerPx: seqPerPx,
          lowConfidence: _lowConfidenceNow(),
          solving: solving,
          interactive: interactive,
        );

        if (!interactive) {
          return IgnorePointer(
            child: CustomPaint(size: box, painter: painter),
          );
        }

        return MouseRegion(
          opaque: false,
          cursor: SystemMouseCursors.precise,
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: {
              _TrackPanRecognizer:
                  GestureRecognizerFactoryWithHandlers<_TrackPanRecognizer>(
                    () => _TrackPanRecognizer(),
                    (r) {
                      r.wantsDrag = (p) => _onPointerDown(p, box);
                      r.onUpdate = (d) => _onPanUpdate(d.localPosition, box);
                      r.onEnd = (_) => _onPanEnd(box);
                      r.onCancel = _reset;
                    },
                  ),
            },
            child: CustomPaint(size: box, painter: painter),
          ),
        );
      },
    );
  }

  /// Centre of the tracked quad across the whole solve, so the shape of the
  /// move is legible without scrubbing (UX notes).
  List<Offset> _trail() {
    final clip = _clip;
    final tracker = _tracker;
    if (clip == null || tracker == null) return const [];
    return [
      for (final entry in c.trackedQuadsInSequence(tracker, clip))
        () {
          final centre = quadCentre(entry.quad);
          return Offset(centre.x, centre.y);
        }(),
    ];
  }

  bool _lowConfidenceNow() {
    final clip = _clip;
    final tracker = _tracker;
    if (clip == null || tracker == null) return false;
    return tracker.confidenceAt(c.clipLocalTime(clip)) < 0.4;
  }
}

/// Pan recognizer gated at pointer-down, so the monitor keeps every gesture it
/// had before this tool was layered on top. See [CanvasGizmo]'s equivalent.
class _TrackPanRecognizer extends PanGestureRecognizer {
  bool Function(Offset localPosition)? wantsDrag;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (wantsDrag?.call(event.localPosition) != true) {
      resolve(GestureDisposition.rejected);
      return;
    }
    super.addAllowedPointer(event);
  }
}

class _AreaTrackPainter extends CustomPainter {
  const _AreaTrackPainter({
    required this.quad,
    required this.drawing,
    required this.trail,
    required this.seqPerPx,
    required this.lowConfidence,
    required this.solving,
    required this.interactive,
  });

  /// The tracked (or being-corrected) region, in sequence px.
  final Quad? quad;

  /// A rectangle currently being dragged out, in widget px.
  final Rect? drawing;

  /// Tracked centres in sequence px.
  final List<Offset> trail;

  final double seqPerPx;
  final bool lowConfidence;

  /// A solve is in flight for this region, so the outline is drawn faded and
  /// without handles — the one visible difference between "tracked" and "still
  /// thinking".
  final bool solving;

  /// Corners can be dragged, so they are drawn as grab points. When false this
  /// is a readout, not a control.
  final bool interactive;

  Offset _px(double x, double y) => Offset(x / seqPerPx, y / seqPerPx);

  @override
  void paint(Canvas canvas, Size size) {
    if (trail.length > 1) {
      final path = Path();
      for (var i = 0; i < trail.length; i += 1) {
        final p = _px(trail[i].dx, trail[i].dy);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = CcColors.accent.withValues(alpha: 0.45),
      );
    }

    final active = quad;
    if (active != null) {
      final path = Path();
      for (var i = 0; i < 4; i += 1) {
        final p = _px(active[2 * i], active[2 * i + 1]);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      // A drifting track is worth seeing without reading a number.
      final colour = lowConfidence ? CcColors.warning : CcColors.accent;
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = solving ? colour.withValues(alpha: 0.55) : colour,
      );
      if (!interactive) return;  // a readout has nothing to grab
      for (var i = 0; i < 4; i += 1) {
        final p = _px(active[2 * i], active[2 * i + 1]);
        final handle = Rect.fromCenter(
          center: p,
          width: _AreaTrackOverlayStateMetrics.handle,
          height: _AreaTrackOverlayStateMetrics.handle,
        );
        canvas.drawRect(handle, Paint()..color = CcColors.panel);
        canvas.drawRect(
          handle,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = colour,
        );
      }
    }

    final rect = drawing;
    if (rect != null) {
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = CcColors.accent,
      );
      canvas.drawRect(
        rect,
        Paint()..color = CcColors.accent.withValues(alpha: 0.12),
      );
    }
  }

  @override
  bool shouldRepaint(_AreaTrackPainter old) =>
      old.quad != quad ||
      old.drawing != drawing ||
      old.seqPerPx != seqPerPx ||
      old.lowConfidence != lowConfidence ||
      old.solving != solving ||
      old.interactive != interactive ||
      old.trail.length != trail.length;
}

/// Painter metrics kept next to the painter rather than reaching into the
/// state class it draws for.
class _AreaTrackOverlayStateMetrics {
  static const double handle = _AreaTrackOverlayState._handleSize;
}
