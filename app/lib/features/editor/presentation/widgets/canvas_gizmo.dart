import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Clip;

import '../../../../core/design/tokens.dart';
import '../../../../data/param_value.dart';
import '../../../../data/project.dart';
import '../../../../models/rational.dart';
import '../../../../state/canvas_geometry.dart';
import '../../../../state/editor_controller.dart';

/// What a pointer landed on: which part, which handle if it was one, and the
/// clip it belongs to — a click can land on an image other than the one the
/// handles are currently drawn around.
class _Hit {
  const _Hit(this.part, [this.handle = 4, this.clip]);

  final GizmoPart part;
  final int handle;
  final Clip? clip;
}

/// TXT-6 on-canvas transform: drag the image on the program monitor to move it,
/// drag a handle to resize it, drag the knob above it to rotate.
///
/// Every edit goes through [EditorController.setTransformParam], so the preview
/// isolate and the export worker pick it up from the same `ClipTransform` the
/// inspector sliders write — nothing here is preview-only.
///
/// Scale is uniform: `ClipTransform` (and the engine's `CompositedLayer`) carry
/// a single `scale`, so edge handles resize proportionally like corners do.
class CanvasGizmo extends StatefulWidget {
  const CanvasGizmo({super.key, required this.controller});

  final EditorController controller;

  @override
  State<CanvasGizmo> createState() => _CanvasGizmoState();
}

class _CanvasGizmoState extends State<CanvasGizmo> {
  static const double _handleSize = 9;
  static const double _hitSlop = 11;
  static const double _rotateOffset = 26;

  EditorController get c => widget.controller;

  // Drag state. `_drag` is null between gestures.
  String? _clipId;
  GizmoDrag? _drag;
  _Hit _hover = const _Hit(GizmoPart.none);

  // --- Geometry -------------------------------------------------------------

  Clip? get _clip => c.gizmoClipUnderPlayhead();

  /// Clip-local time the drag writes at — the same value the inspector's
  /// transform rows pass to [EditorController.setTransformParam].
  Rt _localTime(Clip clip) =>
      c.playhead.minus(clip.start).clampTo(Rt.zero(), clip.duration);

  double _evalNum(ParamValue param, Clip clip, double fallback) {
    final v = param.evaluate(_localTime(clip));
    return v is num ? v.toDouble() : fallback;
  }

  /// Sequence px per widget px. The monitor's box is the whole sequence canvas
  /// (the isolate always renders at sequence aspect), so one factor covers both
  /// axes. `previewFrameSize` is deliberately not used — it is throttled during
  /// playback and would make the handles drift off the image.
  double _seqPerPx(Size box) =>
      box.width <= 0 ? 1 : c.doc.settings.width / box.width;

  /// The clip's unrotated rect in sequence pixels at the current playhead.
  Rect? _rectSeq(Clip clip) {
    final size = c.gizmoSourceSize(clip);
    if (size == null) return null;
    final t = clip.transformOrDefault;
    final anchor = t.anchor.evaluate(_localTime(clip));
    double axis(String key) =>
        anchor is Map && anchor[key] is num ? (anchor[key] as num).toDouble() : 0;
    return layerRectInSequence(
      seqW: c.doc.settings.width,
      seqH: c.doc.settings.height,
      srcW: size.$1,
      srcH: size.$2,
      framing: t.framing,
      x: _evalNum(t.x, clip, 0),
      y: _evalNum(t.y, clip, 0),
      scalePercent: _evalNum(t.scale, clip, 100),
      anchorX: axis('x'),
      anchorY: axis('y'),
    );
  }

  /// The rect a `scale` of 100 would produce, used to invert a drag back into
  /// a scale percentage.
  Rect? _unitRect(Clip clip) {
    final size = c.gizmoSourceSize(clip);
    if (size == null) return null;
    return layerRectInSequence(
      seqW: c.doc.settings.width,
      seqH: c.doc.settings.height,
      srcW: size.$1,
      srcH: size.$2,
      framing: clip.transformOrDefault.framing,
      x: 0,
      y: 0,
      scalePercent: 100,
    );
  }

  double _rotation(Clip clip) =>
      _evalNum(clip.transformOrDefault.rotation, clip, 0);

  /// Handle centres in widget space, in [gizmoAnchors] order, rotated about the
  /// rect centre exactly as the compositor rotates the image.
  List<Offset> _handlePoints(Rect rectSeq, double rotation, double seqPerPx) => [
    for (final p in gizmoAnchors(rectSeq))
      rotatePoint(p, rectSeq.center, rotation) / seqPerPx,
  ];

  Offset _rotateKnob(Rect rectSeq, double rotation, double seqPerPx) {
    final top = rectSeq.topCenter.translate(0, -_rotateOffset * seqPerPx);
    return rotatePoint(top, rectSeq.center, rotation) / seqPerPx;
  }

  // --- Hit testing ----------------------------------------------------------

  _Hit _hitTest(Offset local, Size box) {
    final seqPerPx = _seqPerPx(box);
    final target = _clip;

    // The current target's chrome wins: its handles and rotation knob sit
    // outside its rect, and reaching for one must not select whatever is
    // behind them.
    if (target != null) {
      final rect = _rectSeq(target);
      if (rect != null) {
        final rotation = _rotation(target);
        if ((_rotateKnob(rect, rotation, seqPerPx) - local).distance <=
            _hitSlop) {
          return _Hit(GizmoPart.rotate, 4, target);
        }
        final points = _handlePoints(rect, rotation, seqPerPx);
        for (var i = 0; i < points.length; i += 1) {
          if (i == 4) continue; // the centre is not a handle
          if ((points[i] - local).distance <= _hitSlop) {
            return _Hit(GizmoPart.resize, i, target);
          }
        }
      }
    }

    // Otherwise the click picks the front-most image it actually landed on.
    // Targeting only the selected clip meant that with two images on screen,
    // dragging one of them moved the other.
    for (final clip in c.gizmoClipsUnderPlayhead()) {
      final rect = _rectSeq(clip);
      if (rect == null) continue;
      // The inside test runs in the rect's own unrotated frame.
      final point = rotatePoint(local * seqPerPx, rect.center, -_rotation(clip));
      if (rect.contains(point)) return _Hit(GizmoPart.move, 4, clip);
    }
    return const _Hit(GizmoPart.none);
  }

  static MouseCursor _cursorFor(_Hit hit) => switch (hit.part) {
    GizmoPart.move => SystemMouseCursors.move,
    GizmoPart.rotate => SystemMouseCursors.grab,
    GizmoPart.resize => switch (hit.handle) {
      1 || 7 => SystemMouseCursors.resizeUpDown,
      3 || 5 => SystemMouseCursors.resizeLeftRight,
      0 || 8 => SystemMouseCursors.resizeUpLeftDownRight,
      _ => SystemMouseCursors.resizeUpRightDownLeft,
    },
    GizmoPart.none => MouseCursor.defer,
  };

  // --- Dragging -------------------------------------------------------------

  bool get _altHeld => HardwareKeyboard.instance.isAltPressed;
  bool get _shiftHeld => HardwareKeyboard.instance.isShiftPressed;

  void _onPanStart(Offset local, Size box) {
    final hit = _hitTest(local, box);
    final clip = hit.clip;
    if (hit.part == GizmoPart.none || clip == null) return;
    final rect = _rectSeq(clip);
    final unit = _unitRect(clip);
    if (rect == null || unit == null) return;

    // Start values come from the resting pose, which is what a rebasing write
    // moves. On a clip with no generated animation that is just its transform.
    final resting = c.imageAnimResting(clip);
    _clipId = clip.id;
    _drag = GizmoDrag(
      part: hit.part,
      handle: hit.handle,
      grab: local * _seqPerPx(box),
      rect: rect,
      unitRect: unit,
      restingX: resting['x']!,
      restingY: resting['y']!,
      restingScale: resting['scale']!,
      drawnScale: _evalNum(clip.transformOrDefault.scale, clip, 100),
      rotation: _rotation(clip),
      symmetric: _altHeld,
    );

    // One undo step per gesture (TIM-20); markDirty also skips engine sync
    // until endGesture, so a drag does not re-encode the project per frame.
    c.beginGesture(switch (hit.part) {
      GizmoPart.move => 'Move image',
      GizmoPart.resize => 'Resize image',
      _ => 'Rotate image',
    });
    if (!c.selection.contains(clip.id)) {
      c.selection
        ..clear()
        ..add(clip.id);
    }
    setState(() {});
  }

  void _onPanUpdate(Offset local, Size box) {
    final drag = _drag;
    final id = _clipId;
    if (drag == null || id == null) return;
    final clip = c.doc.clipById(id);
    if (clip == null) return;

    final at = _localTime(clip);
    final next = drag.resolve(local * _seqPerPx(box), snap: _shiftHeld);
    // Rotation is not part of the generated animation, so it keyframes the way
    // the inspector's rotation slider does.
    if (next.rotation case final rotation?) {
      c.setTransformParam(id, 'rotation', rotation, at: at);
    }
    if (next.scale case final scale?) {
      c.setTransformParam(id, 'scale', scale, at: at, rebase: true);
    }
    if (next.x case final x?) {
      c.setTransformParam(id, 'x', x, at: at, rebase: true);
    }
    if (next.y case final y?) {
      c.setTransformParam(id, 'y', y, at: at, rebase: true);
    }
    // The gesture is still open, so the committed-edit path has not synced the
    // engine yet. Without this the monitor keeps painting the pre-drag frame
    // while the handles track the pointer, which reads as the image drifting
    // out of its own box.
    c.previewLiveEdit();
  }

  void _onPanEnd() {
    if (_drag == null) return;
    _drag = null;
    _clipId = null;
    c.endGesture();
    setState(() {});
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // A gizmo over moving frames is noise, and its handles would fight the
    // transport for the pointer.
    if (c.playing) return const SizedBox.shrink();
    final clip = _clip;
    if (clip == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final box = constraints.biggest;
        final rect = _rectSeq(clip);
        if (rect == null) return const SizedBox.shrink();

        return MouseRegion(
          opaque: false,
          cursor: _cursorFor(
            _drag == null ? _hover : _Hit(_drag!.part, _drag!.handle),
          ),
          onHover: (event) {
            final hit = _hitTest(event.localPosition, box);
            if (hit.part != _hover.part || hit.handle != _hover.handle) {
              setState(() => _hover = hit);
            }
          },
          onExit: (_) {
            if (_hover.part != GizmoPart.none) {
              setState(() => _hover = const _Hit(GizmoPart.none));
            }
          },
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: {
              // A gated recognizer keeps the monitor's double-tap-to-edit-text
              // alive: the pan only enters the arena when the pointer actually
              // lands on the gizmo, so taps elsewhere fall through.
              _GizmoPanRecognizer:
                  GestureRecognizerFactoryWithHandlers<_GizmoPanRecognizer>(
                    () => _GizmoPanRecognizer(),
                    (r) {
                      r.claims = (position) =>
                          _hitTest(position, box).part != GizmoPart.none;
                      r.onStart = (d) => _onPanStart(d.localPosition, box);
                      r.onUpdate = (d) => _onPanUpdate(d.localPosition, box);
                      r.onEnd = (_) => _onPanEnd();
                      r.onCancel = _onPanEnd;
                    },
                  ),
            },
            child: CustomPaint(
              size: box,
              painter: _GizmoPainter(
                rect: rect,
                rotation: _rotation(clip),
                seqPerPx: _seqPerPx(box),
                hoverHandle:
                    _hover.part == GizmoPart.resize ? _hover.handle : -1,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Pan recognizer that only competes for pointers landing on the gizmo, so the
/// monitor keeps every gesture it had before the gizmo was layered on top.
class _GizmoPanRecognizer extends PanGestureRecognizer {
  bool Function(Offset localPosition)? claims;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (claims?.call(event.localPosition) != true) {
      resolve(GestureDisposition.rejected);
      return;
    }
    super.addAllowedPointer(event);
  }
}

class _GizmoPainter extends CustomPainter {
  const _GizmoPainter({
    required this.rect,
    required this.rotation,
    required this.seqPerPx,
    required this.hoverHandle,
  });

  /// Unrotated rect, in sequence pixels.
  final Rect rect;
  final double rotation;
  final double seqPerPx;
  final int hoverHandle;

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = CcColors.accent;
    final hoverFill = Paint()..color = CcColors.accent;
    final chromeFill = Paint()..color = CcColors.bg;

    final box = Rect.fromLTRB(
      rect.left / seqPerPx,
      rect.top / seqPerPx,
      rect.right / seqPerPx,
      rect.bottom / seqPerPx,
    );

    canvas.save();
    canvas.translate(box.center.dx, box.center.dy);
    canvas.rotate(rotation * math.pi / 180);
    canvas.translate(-box.center.dx, -box.center.dy);

    canvas.drawRect(box, outline);

    final knob = box.topCenter.translate(0, -_CanvasGizmoState._rotateOffset);
    canvas.drawLine(box.topCenter, knob, outline);
    canvas.drawCircle(knob, 5, chromeFill);
    canvas.drawCircle(knob, 5, outline);

    final anchors = gizmoAnchors(box);
    for (var i = 0; i < anchors.length; i += 1) {
      if (i == 4) continue;
      final side = i == hoverHandle
          ? _CanvasGizmoState._handleSize + 2
          : _CanvasGizmoState._handleSize;
      final square =
          Rect.fromCenter(center: anchors[i], width: side, height: side);
      canvas.drawRect(square, chromeFill);
      canvas.drawRect(square, i == hoverHandle ? hoverFill : outline);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GizmoPainter old) =>
      old.rect != rect ||
      old.rotation != rotation ||
      old.seqPerPx != seqPerPx ||
      old.hoverHandle != hoverHandle;
}
