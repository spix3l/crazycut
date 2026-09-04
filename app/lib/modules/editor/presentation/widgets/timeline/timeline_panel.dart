import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/cc_dialog.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/project/domain/caption.dart';
import 'package:crazycut_app/modules/project/domain/project.dart';
import 'package:crazycut_app/modules/project/domain/transition.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import 'package:crazycut_app/modules/editor/application/timeline_edits.dart';
import 'package:crazycut_app/modules/editor/presentation/models/editor_models.dart';
import 'package:crazycut_app/modules/editor/presentation/widgets/templates/template_dialogs.dart';
import 'timeline_clip_tile.dart';
import 'track_header.dart';

part 'ruler_painter.dart';

/// How far from a keyframe diamond a click still counts as hitting it. The
/// diamonds are small on purpose; the target around them is not.
const double _kKeyframeHitPx = 7;

/// Widest a trim handle gets. Narrow clips get proportionally thinner ones so
/// the middle of the tile stays grabbable.
const double _kTrimHandlePx = 7;

/// Bottom half of the editor: tool strip, ruler, track headers, lanes and the
/// playhead. The panel turns pixels into times and hands every mutation to the
/// controller — it owns no document state of its own.
class TimelinePanel extends StatefulWidget {
  const TimelinePanel({
    super.key,
    required this.controller,
    required this.pxPerSec,
    required this.snap,
    this.onSnapChanged,
    this.onZoomChanged,
    this.onZoomAt,
    this.onFit,
    this.onAutoCaptions,
    this.onCancelAutoCaptions,
    this.modelDownloadProgress,
  });

  static const double rulerHeight = 26;

  final EditorController controller;
  final double pxPerSec;
  final bool snap;
  final ValueChanged<bool>? onSnapChanged;
  final ValueChanged<double>? onZoomChanged;

  /// Pointer-anchored zoom: (steps, seconds under the pointer) (TIM-14).
  final void Function(double steps, double anchorSeconds)? onZoomAt;
  final VoidCallback? onFit;
  final VoidCallback? onAutoCaptions;
  final VoidCallback? onCancelAutoCaptions;
  final double? modelDownloadProgress;

  @override
  State<TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends State<TimelinePanel> {
  static const double _captionLaneHeight = 44;

  /// Trackpad pan/zoom streams are navigation input. Keeping them out of edit
  /// recognizers lets the nested scroll views consume two-finger scrolling
  /// without starting a marquee, moving a clip, or retiming an edit.
  static const _editPointerDevices = <PointerDeviceKind>{
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  final _headerScroll = ScrollController();
  final _laneScroll = ScrollController();
  final _horizontal = ScrollController();
  bool _syncing = false;

  double _scrollX = 0;
  double _viewportWidth = 800;
  double _viewportHeight = 400;

  // Drag bookkeeping in pixels; the controller works from gesture origins.
  Offset _dragDelta = Offset.zero;
  bool _dragging = false;
  EditGesture? _dragKind;
  double? _zoomAnchorSeconds;
  Offset? _marqueeStart;
  Offset? _marqueeEnd;
  bool _marqueeAdditive = false;

  /// Marquee autoscroll: while the pointer sits near (or past) the viewport
  /// edge the timeline keeps scrolling so the selection can grow beyond what
  /// was first visible. [_marqueeViewport] is the pointer in viewport pixels,
  /// which stays put while the content slides underneath it.
  Timer? _marqueeTimer;
  Offset _marqueeViewport = Offset.zero;
  static const double _marqueeEdgePx = 40;

  /// Trackpad pinch state. [PointerPanZoomUpdateEvent.scale] is cumulative
  /// since the gesture started, so the delta from the last event is what
  /// zooms.
  double _lastPanZoomScale = 1.0;

  /// Touch pinch state. Tracked manually in the [Listener] so a one-finger
  /// marquee never enters the gesture arena against a two-finger zoom.
  final Map<int, Offset> _touchPointers = {};
  double? _pinchStartDistance;
  double? _pinchStartPxPerSec;
  String? _dropTrackId;
  double? _dropSeconds;
  String? _draggingMarkerId;
  Rt? _captionDragStart;
  Rt? _captionDragDuration;
  double _captionDragSeconds = 0;

  EditorController get c => widget.controller;
  ProjectDoc get doc => c.doc;
  double get pxPerSec => widget.pxPerSec;

  /// Lanes shrink as the timeline zooms out so more tracks fit on screen.
  double get _laneScale => timelineLaneScaleForPixelsPerSecond(pxPerSec);

  /// Displayed lane height: the authored [Track.height] scaled by the zoom.
  double _laneHeight(Track track) => track.height * _laneScale;

  @override
  void initState() {
    super.initState();
    _headerScroll.addListener(() => _mirror(_headerScroll, _laneScroll));
    _laneScroll.addListener(() => _mirror(_laneScroll, _headerScroll));
    _horizontal.addListener(() {
      if (!_horizontal.hasClients) return;
      setState(() => _scrollX = _horizontal.offset);
    });
  }

  /// Keeps the header gutter and the lanes on the same vertical offset without
  /// pulling in a linked-controller package.
  void _mirror(ScrollController from, ScrollController to) {
    if (_syncing || !to.hasClients || !from.hasClients) return;
    if ((to.offset - from.offset).abs() < 0.5) return;
    _syncing = true;
    to.jumpTo(
      from.offset.clamp(
        to.position.minScrollExtent,
        to.position.maxScrollExtent,
      ),
    );
    _syncing = false;
  }

  @override
  void didUpdateWidget(TimelinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pxPerSec == widget.pxPerSec) return;
    // Keep the anchored time under the pointer after a zoom step (TIM-14);
    // otherwise keep the left edge stable.
    final anchor = _zoomAnchorSeconds;
    _zoomAnchorSeconds = null;
    if (!_horizontal.hasClients) return;
    final pointerOffset =
        anchor == null ? 0.0 : anchor * oldWidget.pxPerSec - _scrollX;
    final target =
        anchor == null
            ? _scrollX * widget.pxPerSec / oldWidget.pxPerSec
            : anchor * widget.pxPerSec - pointerOffset;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_horizontal.hasClients) return;
      _horizontal.jumpTo(
        target.clamp(0.0, _horizontal.position.maxScrollExtent),
      );
    });
  }

  @override
  void dispose() {
    _marqueeTimer?.cancel();
    _headerScroll.dispose();
    _laneScroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _cancelMarqueeAutoscroll() {
    _marqueeTimer?.cancel();
    _marqueeTimer = null;
  }

  double _laneScrollOffset() =>
      _laneScroll.hasClients ? _laneScroll.offset : 0.0;

  void _noteMarqueeViewport(Track track, Offset local) {
    final content = local + Offset(0, _laneTop(track));
    // Viewport pixels: content minus scrolled offset. May sit outside
    // [0, viewport] when the pointer is dragged past the edge, which is
    // exactly when the autoscroll has to keep going.
    _marqueeViewport = Offset(
      content.dx - _scrollX,
      content.dy - _laneScrollOffset(),
    );
  }

  void _maybeStartMarqueeAutoscroll() {
    if (_marqueeStart == null || _marqueeEnd == null) return;
    final v = _marqueeViewport;
    final nearHorizontal =
        v.dx < _marqueeEdgePx || v.dx > _viewportWidth - _marqueeEdgePx;
    final nearVertical =
        v.dy < _marqueeEdgePx || v.dy > _viewportHeight - _marqueeEdgePx;
    if (!nearHorizontal && !nearVertical) {
      _cancelMarqueeAutoscroll();
      return;
    }
    if (_marqueeTimer != null) return;
    _marqueeTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _marqueeTick(),
    );
  }

  double _edgeVelocity(double pos, double size) {
    if (pos < 0) return (pos - 8) * 0.6;
    if (pos > size) return (pos - size + 8) * 0.6;
    if (pos < _marqueeEdgePx) return (pos - _marqueeEdgePx) * 0.6;
    if (pos > size - _marqueeEdgePx) {
      return (pos - (size - _marqueeEdgePx)) * 0.6;
    }
    return 0;
  }

  void _marqueeTick() {
    if (_marqueeStart == null || _marqueeEnd == null) {
      _cancelMarqueeAutoscroll();
      return;
    }
    final vx = _edgeVelocity(_marqueeViewport.dx, _viewportWidth).clamp(
      -48.0,
      48.0,
    );
    final vy = _edgeVelocity(_marqueeViewport.dy, _viewportHeight).clamp(
      -48.0,
      48.0,
    );
    if (vx == 0 && vy == 0) return;
    if (vx != 0) _scrollBy(_horizontal, vx);
    if (vy != 0) _scrollBy(_laneScroll, vy);
    // The pointer stays where it is on screen while the content slides, so
    // the content endpoint has to follow the new scroll offset.
    setState(() {
      _marqueeEnd = Offset(
        _scrollX + _marqueeViewport.dx,
        _laneScrollOffset() + _marqueeViewport.dy,
      );
    });
  }

  // --- Geometry -------------------------------------------------------------

  double _x(Rt t) => t.seconds * pxPerSec;
  Rt _time(double x) =>
      Rt.fromSeconds((x / pxPerSec).clamp(0, double.infinity));

  double get _contentSeconds {
    final content = doc.sequenceDuration.seconds;
    return content + (_viewportWidth / pxPerSec) * 0.5 + 4;
  }

  double get _contentWidth =>
      (_contentSeconds * pxPerSec).clamp(_viewportWidth, double.infinity);

  /// Visible time window, padded so a scroll never shows an empty gap before
  /// the next build (TIM-22 virtualization).
  (double, double) get _visibleRange {
    final pad = _viewportWidth * 0.5;
    return (
      ((_scrollX - pad) / pxPerSec).clamp(0.0, double.infinity),
      (_scrollX + _viewportWidth + pad) / pxPerSec,
    );
  }

  bool get _bypassSnap => HardwareKeyboard.instance.isControlPressed;
  bool get _snapping => widget.snap && !_bypassSnap;

  // --- Clip gestures --------------------------------------------------------

  void _onClipTap(Clip clip) {
    final keys = HardwareKeyboard.instance;
    c.selectClip(
      clip.id,
      additive: keys.isShiftPressed || keys.isMetaPressed,
      withLinked: !keys.isAltPressed,
    );
  }

  void _startClipDrag(Clip clip, EditGesture fallback) {
    final keys = HardwareKeyboard.instance;
    final kind = switch (fallback) {
      EditGesture.move when keys.isAltPressed && !keys.isMetaPressed =>
        EditGesture.slip,
      EditGesture.move when keys.isMetaPressed => EditGesture.slide,
      // Cmd on a trim handle asks for the clip itself: on a clip only a few
      // pixels wide the handles are most of what there is to grab, and the
      // move zone can be too thin to aim at.
      EditGesture.trimStart ||
      EditGesture.trimEnd when keys.isMetaPressed => EditGesture.move,
      _ => fallback,
    };
    _dragDelta = Offset.zero;
    _dragging = true;
    _dragKind = kind;
    c.beginDrag(
      kind,
      clip.id,
      breakLinks: keys.isAltPressed && kind == EditGesture.move,
    );
  }

  void _updateClipDrag(DragUpdateDetails details, {int lanes = 0}) {
    if (!_dragging) return;
    _dragDelta += details.delta;
    c.updateDrag(
      _dragDelta.dx / pxPerSec,
      laneDelta: lanes,
      snap: _snapping,
      pxPerSec: pxPerSec,
    );
  }

  void _endDrag() {
    if (!_dragging) return;
    _dragging = false;
    _dragKind = null;
    c.endGesture();
  }

  /// How many lanes a vertical drag crossed, from the displayed lane heights.
  int _laneDelta(String fromTrackId, double dy) {
    final lanes = c.laneOrder;
    var index = lanes.indexWhere((t) => t.id == fromTrackId);
    if (index < 0) return 0;
    final start = index;
    var remaining = dy;
    while (remaining > 0 && index < lanes.length - 1) {
      final step = _laneHeight(lanes[index]);
      if (remaining < step / 2) break;
      remaining -= step;
      index++;
    }
    while (remaining < 0 && index > 0) {
      final step = _laneHeight(lanes[index - 1]);
      if (-remaining < step / 2) break;
      remaining += step;
      index--;
    }
    return index - start;
  }

  void _clipMenu(BuildContext anchorContext, Clip clip, {Offset? position}) {
    if (!c.selection.contains(clip.id)) c.selectClip(clip.id);
    final linked = clip.linkedGroup != null;
    showCcMenu(
      anchorContext,
      [
      CcMenuItem('Split at playhead', shortcut: 'S', onTap: c.splitAtPlayhead),
      CcMenuItem('Copy', shortcut: '⌘C', onTap: c.copySelection),
      CcMenuItem('Cut', shortcut: '⌘X', onTap: c.cutSelection),
      CcMenuItem(
        'Paste settings',
        shortcut: '⌥⌘V',
        onTap: c.canPasteAttributes ? () => c.pasteAttributes() : null,
      ),
      CcMenuItem(
        'Delete',
        shortcut: '⌫',
        onTap: () => c.deleteSelected(ripple: false),
      ),
      CcMenuItem(
        'Ripple delete',
        shortcut: '⇧⌫',
        onTap: () => c.deleteSelected(ripple: true),
      ),
      CcMenuItem(
        linked ? 'Unlink A/V' : 'Link selection',
        separatorBefore: true,
        onTap:
            linked
                ? c.unlinkSelection
                : (c.selection.length > 1 ? c.linkSelection : null),
      ),
      CcMenuItem(
        clip.mute ? 'Unmute clip' : 'Mute clip',
        onTap: () => c.setClipAudio(clip.id, mute: !clip.mute),
      ),
      // Every preset, checked at the current one: one click to any speed and
      // back, rather than a ratchet that only ever climbs to 4x.
      for (final preset in TimelineEdits.clipSpeedPresets)
        CcMenuItem(
          'Speed ${preset.$3}',
          separatorBefore: preset == TimelineEdits.clipSpeedPresets.first,
          checked: (preset.$1 / preset.$2 - clip.speedValue).abs() < 0.000001,
          onTap: () => c.setClipSpeed(clip.id, preset.$1, preset.$2),
        ),
      CcMenuItem(
        'Save selection as template…',
        shortcut: '⇧⌘T',
        separatorBefore: true,
        onTap: () => showSaveTemplateDialog(context, c),
      ),
      ],
      position: position,
    );
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final lanes = c.laneOrder;
    final captionHeight = doc.captionTracks.length * _captionLaneHeight;
    final lanesHeight =
        captionHeight + lanes.fold<double>(0, (sum, t) => sum + _laneHeight(t));

    return Container(
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: CcBorders.top,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TimelineToolbar(
            controller: c,
            snap: widget.snap,
            zoom: timelineZoomForPixelsPerSecond(pxPerSec),
            onSnapChanged: widget.onSnapChanged,
            onZoomChanged: widget.onZoomChanged,
            onFit: widget.onFit,
            onAutoCaptions: widget.onAutoCaptions,
            onCancelAutoCaptions: widget.onCancelAutoCaptions,
            modelDownloadProgress: widget.modelDownloadProgress,
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: TrackHeaderTile.width,
                  child: Column(
                    children: [
                      Container(
                        height: TimelinePanel.rulerHeight,
                        decoration: const BoxDecoration(
                          color: CcColors.panel,
                          border: Border(
                            right: BorderSide(color: CcColors.border),
                            bottom: BorderSide(color: CcColors.border),
                          ),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _headerScroll,
                          child: Column(
                            children: [
                              for (final track in doc.captionTracks)
                                _captionHeader(track),
                              for (final track in lanes) _header(track),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _viewportWidth = constraints.maxWidth;
                      _viewportHeight =
                          constraints.maxHeight - TimelinePanel.rulerHeight;
                      return Listener(
                        onPointerSignal: _onPointerSignal,
                        onPointerPanZoomStart: _onPanZoomStart,
                        onPointerPanZoomUpdate: _onTrackpadPan,
                        onPointerPanZoomEnd: _onPanZoomEnd,
                        onPointerDown: _onTimelinePointerDown,
                        onPointerMove: _onTimelinePointerMove,
                        onPointerUp: _onTimelinePointerUp,
                        onPointerCancel: _onTimelinePointerUp,
                        child: SingleChildScrollView(
                          controller: _horizontal,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: _contentWidth,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _ruler(),
                                Expanded(
                                  child: SingleChildScrollView(
                                    controller: _laneScroll,
                                    child: SizedBox(
                                      height: math.max(
                                        lanesHeight,
                                        constraints.maxHeight -
                                            TimelinePanel.rulerHeight,
                                      ),
                                      child: Stack(
                                        clipBehavior: ui.Clip.none,
                                        children: [
                                          Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              for (final track
                                                  in doc.captionTracks)
                                                _captionLane(track),
                                              for (final track in lanes)
                                                _lane(track),
                                              Expanded(child: _emptySpace()),
                                            ],
                                          ),
                                          if (doc.clips.isEmpty &&
                                              doc.captionTracks.isEmpty)
                                            const Positioned.fill(
                                              child: IgnorePointer(
                                                child: _GettingStartedHint(),
                                              ),
                                            ),
                                          _inOutOverlay(lanesHeight),
                                          if (c.snapIndicator != null)
                                            Positioned(
                                              left: c.snapIndicator! * pxPerSec,
                                              top: 0,
                                              height: lanesHeight,
                                              child: const IgnorePointer(
                                                child: SizedBox(
                                                  width: 1,
                                                  child: ColoredBox(
                                                    color: CcColors.warning,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          // Tracks the playhead on its own
                                          // notifier so the transport can move
                                          // the cursor without rebuilding
                                          // every clip in the timeline.
                                          ValueListenableBuilder<Rt>(
                                            valueListenable: c.playheadNotifier,
                                            builder:
                                                (context, playhead, child) =>
                                                    Positioned(
                                                      left: _x(playhead) - 1,
                                                      top: 0,
                                                      height: lanesHeight,
                                                      child: child!,
                                                    ),
                                            child: const IgnorePointer(
                                              child: SizedBox(
                                                width: 2,
                                                child: ColoredBox(
                                                  color: CcColors.accent,
                                                ),
                                              ),
                                            ),
                                          ),
                                          if (_marqueeStart != null &&
                                              _marqueeEnd != null)
                                            _marqueeBox(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _captionHeader(CaptionTrack track) {
    final selected = c.selectedCaptionTrackId == track.id;
    return Builder(
      builder:
          (headerContext) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapDown: (_) => _captionTrackMenu(headerContext, track),
            child: CcTappable(
              onTap: () => c.selectCaption(track.id, null),
              child: Container(
                height: _captionLaneHeight,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: selected ? CcColors.textClipPlate : CcColors.panel,
                  border: const Border(
                    right: BorderSide(color: CcColors.border),
                    bottom: BorderSide(color: CcColors.border),
                  ),
                ),
                child: Row(
                  children: [
                    const CcIcon(
                      LucideIcons.captions,
                      size: 13,
                      color: CcColors.textClip,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        track.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.style(size: 11, weight: CcType.medium),
                      ),
                    ),
                    CcIconButton(
                      key: ValueKey('caption-track-menu-${track.id}'),
                      icon: LucideIcons.ellipsis,
                      size: 24,
                      iconSize: 13,
                      onPressed: () => _captionTrackMenu(headerContext, track),
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  void _captionTrackMenu(BuildContext context, CaptionTrack track) {
    showCcMenu(context, [
      CcMenuItem(
        'Add caption at playhead',
        icon: LucideIcons.plus,
        onTap: () {
          c.selectCaption(track.id, null);
          c.addCaptionItem(at: c.playhead);
        },
      ),
      CcMenuItem(
        'Delete caption track',
        icon: LucideIcons.trash2,
        danger: true,
        separatorBefore: true,
        onTap: () => c.deleteCaptionTrack(track.id),
      ),
    ]);
  }

  Widget _captionLane(CaptionTrack track) {
    final (visibleFrom, visibleTo) = _visibleRange;
    final visible = track.items.where(
      (item) =>
          item.end.seconds >= visibleFrom && item.start.seconds <= visibleTo,
    );
    return SizedBox(
      height: _captionLaneHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                c.selectCaption(track.id, null);
                c.seekTo(_time(details.localPosition.dx));
              },
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  color: CcColors.bg,
                  border: Border(bottom: BorderSide(color: CcColors.border)),
                ),
              ),
            ),
          ),
          for (final item in visible) _captionTile(track, item),
        ],
      ),
    );
  }

  Widget _captionTile(CaptionTrack track, CaptionItem item) {
    final selected = c.selectedCaptionItemId == item.id;
    final width = (item.duration.seconds * pxPerSec).clamp(
      3.0,
      double.infinity,
    );

    void begin() {
      _captionDragStart = item.start;
      _captionDragDuration = item.duration;
      _captionDragSeconds = 0;
      c.beginGesture('Retime caption');
    }

    void end() {
      _captionDragStart = null;
      _captionDragDuration = null;
      _captionDragSeconds = 0;
      c.endGesture();
    }

    Widget handle({required bool start}) => Positioned(
      left: start ? 0 : null,
      right: start ? null : 0,
      top: 0,
      bottom: 0,
      width: 7,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => begin(),
          onHorizontalDragUpdate: (details) {
            _captionDragSeconds += details.delta.dx / pxPerSec;
            final originStart = _captionDragStart!;
            final originDuration = _captionDragDuration!;
            final delta = Rt.fromSeconds(_captionDragSeconds);
            if (start) {
              final nextStart = originStart.plus(delta);
              c.retimeCaption(
                track.id,
                item.id,
                start: nextStart,
                duration: originDuration.minus(nextStart.minus(originStart)),
              );
            } else {
              c.retimeCaption(
                track.id,
                item.id,
                duration: originDuration.plus(delta),
              );
            }
          },
          onHorizontalDragEnd: (_) => end(),
          onHorizontalDragCancel: end,
        ),
      ),
    );

    return Positioned(
      left: _x(item.start),
      top: 3,
      height: _captionLaneHeight - 6,
      width: width,
      child: Builder(
        builder:
            (tileContext) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => c.selectCaption(track.id, item.id, seek: true),
              onSecondaryTapDown:
                  (d) => showCcMenu(
                    tileContext,
                    [
                      CcMenuItem(
                        'Split at playhead',
                        onTap:
                            () => c.splitCaption(track.id, item.id, c.playhead),
                      ),
                      CcMenuItem(
                        'Merge with next',
                        onTap: () => c.mergeCaptionWithNext(track.id, item.id),
                      ),
                      CcMenuItem(
                        'Nudge left',
                        onTap: () => c.nudgeCaption(track.id, item.id, -1),
                      ),
                      CcMenuItem(
                        'Nudge right',
                        onTap: () => c.nudgeCaption(track.id, item.id, 1),
                      ),
                    ],
                    position: d.globalPosition,
                  ),
              onHorizontalDragStart: (_) => begin(),
              onHorizontalDragUpdate: (details) {
                _captionDragSeconds += details.delta.dx / pxPerSec;
                c.retimeCaption(
                  track.id,
                  item.id,
                  start: _captionDragStart!.plus(
                    Rt.fromSeconds(_captionDragSeconds),
                  ),
                  duration: _captionDragDuration,
                );
              },
              onHorizontalDragEnd: (_) => end(),
              onHorizontalDragCancel: end,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected ? CcColors.textClip : CcColors.textClipPlate,
                  border: Border.all(
                    color: selected ? CcColors.textPrimary : CcColors.textClip,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Text(
                        item.text.isEmpty ? '(empty caption)' : item.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.style(size: 10),
                      ),
                    ),
                    handle(start: true),
                    handle(start: false),
                  ],
                ),
              ),
            ),
      ),
    );
  }

  /// Trackpad pinch, or ⌘/⌃ + wheel, zooms around the pointer; a plain wheel
  /// scrolls (TIM-14).
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScaleEvent) {
      final anchor = (_scrollX + event.localPosition.dx) / pxPerSec;
      _zoomAnchorSeconds = anchor;
      widget.onZoomAt?.call((event.scale - 1) * 4, anchor);
      return;
    }
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    if (!keys.isMetaPressed && !keys.isControlPressed) return;
    final anchor = (_scrollX + event.localPosition.dx) / pxPerSec;
    _zoomAnchorSeconds = anchor;
    widget.onZoomAt?.call(-event.scrollDelta.dy / 240, anchor);
  }

  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    _lastPanZoomScale = 1.0;
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    _lastPanZoomScale = 1.0;
  }

  /// Routes a two-finger trackpad gesture to timeline navigation: a pinch
  /// zooms around the pointer, a pan scrolls with the dominant axis winning
  /// so a slightly diagonal gesture does not drift in both directions.
  void _onTrackpadPan(PointerPanZoomUpdateEvent event) {
    final scale = event.scale == 0 ? 1.0 : event.scale;
    final last = _lastPanZoomScale <= 0 ? 1.0 : _lastPanZoomScale;
    _lastPanZoomScale = scale;
    // Scale is cumulative, so only the delta since the last event zooms.
    // Pan is independent: a held pinch followed by a two-finger drag must
    // still scroll instead of freezing while the fingers stay down.
    if ((scale - 1).abs() > 0.001 || (last - 1).abs() > 0.001) {
      final ratio = (scale / last).clamp(0.5, 2.0);
      if ((ratio - 1).abs() >= 0.0005) {
        final anchor = (_scrollX + event.localPosition.dx) / pxPerSec;
        _zoomAnchorSeconds = anchor;
        // Match the PointerScaleEvent path above: a scale factor maps to zoom
        // steps, anchored under the pointer.
        widget.onZoomAt?.call((ratio - 1) * 4, anchor);
      }
    }
    final delta = event.localPanDelta;
    if (delta.dx.abs() >= delta.dy.abs()) {
      _scrollBy(_horizontal, -delta.dx);
    } else {
      _scrollBy(_laneScroll, -delta.dy);
    }
  }

  void _onTimelinePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touchPointers[event.pointer] = event.localPosition;
    if (_touchPointers.length == 2) {
      final points = _touchPointers.values.toList();
      _pinchStartDistance = (points[0] - points[1]).distance;
      _pinchStartPxPerSec = pxPerSec;
      final focal = (points[0] + points[1]) / 2;
      _zoomAnchorSeconds = (_scrollX + focal.dx) / pxPerSec;
      // A second finger means zoom, not a growing selection.
      if (_marqueeStart != null) {
        _cancelMarqueeAutoscroll();
        setState(() {
          _marqueeStart = null;
          _marqueeEnd = null;
        });
      }
      _endDrag();
    }
  }

  void _onTimelinePointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    if (!_touchPointers.containsKey(event.pointer)) return;
    _touchPointers[event.pointer] = event.localPosition;
    if (_touchPointers.length == 2) {
      final points = _touchPointers.values.toList();
      final distance = (points[0] - points[1]).distance;
      final startDistance = _pinchStartDistance ?? 0;
      final startPx = _pinchStartPxPerSec ?? pxPerSec;
      if (startDistance < 10 || distance < 1) return;
      final focal = (points[0] + points[1]) / 2;
      _zoomAnchorSeconds = (_scrollX + focal.dx) / pxPerSec;
      final nextPx = (startPx * distance / startDistance).clamp(
        kMinPxPerSec,
        kMaxPxPerSec,
      );
      widget.onZoomChanged?.call(timelineZoomForPixelsPerSecond(nextPx));
    }
  }

  void _onTimelinePointerUp(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touchPointers.remove(event.pointer);
    if (_touchPointers.length < 2) {
      _pinchStartDistance = null;
      _pinchStartPxPerSec = null;
      if (_touchPointers.length == 1) {
        // The remaining finger becomes a fresh single touch; keep its latest
        // position so a continuing drag does not jump.
        final remaining = _touchPointers.entries.single;
        _touchPointers[remaining.key] = remaining.value;
      }
    }
  }

  void _scrollBy(ScrollController controller, double delta) {
    if (!controller.hasClients || delta == 0) return;
    controller.jumpTo(
      (controller.offset + delta).clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      ),
    );
  }

  Widget _header(Track track) {
    return DragTarget<String>(
      key: ValueKey('track-drop-target-${track.id}'),
      onWillAcceptWithDetails: (details) => _canDropTrack(details.data, track),
      onAcceptWithDetails: (details) => _dropTrackOn(details.data, track),
      builder: (context, candidates, rejected) {
        final accepting = candidates.whereType<String>().any(
          (id) => _canDropTrack(id, track),
        );
        return Stack(
          children: [
            TrackHeaderTile(
              track: track,
              height: _laneHeight(track),
              selected: doc
                  .clipsOn(track.id)
                  .any((clip) => c.selection.contains(clip.id)),
              dragHandle: _trackDragHandle(track),
              onSelect:
                  () => c.selectTrack(
                    track.id,
                    additive: HardwareKeyboard.instance.isShiftPressed,
                  ),
              onRename: (name) => c.renameTrack(track.id, name),
              onToggleMute: () => c.setTrackFlags(track.id, mute: !track.mute),
              onToggleSolo: () => c.setTrackFlags(track.id, solo: !track.solo),
              onToggleHidden:
                  () => c.setTrackFlags(track.id, hidden: !track.hidden),
              onToggleLock: () => c.setTrackFlags(track.id, lock: !track.lock),
              onCycleHeight: () {
                const order = TrackHeight.values;
                final current = TrackHeight.nearest(track.height);
                c.setTrackHeight(
                  track.id,
                  order[(order.indexOf(current) + 1) % order.length],
                );
              },
              onReorder: (delta) => c.reorderTrack(track.id, delta),
              onRemove: () => c.removeTrack(track.id),
            ),
            if (accepting)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: CcColors.accent.withValues(alpha: 0.08),
                      border: Border.all(color: CcColors.accent, width: 2),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  bool _canDropTrack(String draggedId, Track target) {
    final dragged = doc.trackById(draggedId);
    return dragged != null &&
        dragged.id != target.id &&
        dragged.kind == target.kind;
  }

  void _dropTrackOn(String draggedId, Track target) {
    final dragged = doc.trackById(draggedId);
    if (dragged == null || dragged.kind != target.kind) return;
    final peers = dragged.isVideo ? doc.videoTracks : doc.audioTracks;
    final from = peers.indexWhere((track) => track.id == draggedId);
    final to = peers.indexWhere((track) => track.id == target.id);
    if (from < 0 || to < 0) return;
    c.reorderTrack(draggedId, to - from);
  }

  Widget _trackDragHandle(Track track) {
    return Draggable<String>(
      data: track.id,
      axis: Axis.vertical,
      feedback: Opacity(
        opacity: 0.9,
        child: SizedBox(
          width: TrackHeaderTile.width,
          child: TrackHeaderTile(track: track, height: _laneHeight(track)),
        ),
      ),
      childWhenDragging: const Opacity(
        opacity: 0.3,
        child: CcIcon(
          LucideIcons.gripVertical,
          size: 13,
          color: CcColors.textTertiary,
        ),
      ),
      child: MouseRegion(
        key: ValueKey('track-drag-handle-${track.id}'),
        cursor: SystemMouseCursors.grab,
        child: const CcTooltip(
          message: 'Drag to reorder lane',
          child: CcIcon(
            LucideIcons.gripVertical,
            size: 13,
            color: CcColors.textTertiary,
          ),
        ),
      ),
    );
  }

  // --- Ruler ----------------------------------------------------------------

  Widget _ruler() {
    return GestureDetector(
      supportedDevices: _editPointerDevices,
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => c.seekTo(_time(d.localPosition.dx)),
      onHorizontalDragStart: (d) => c.seekTo(_time(d.localPosition.dx)),
      onHorizontalDragUpdate: (d) => c.seekTo(_time(d.localPosition.dx)),
      child: SizedBox(
        height: TimelinePanel.rulerHeight,
        child: Stack(
          clipBehavior: ui.Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: RulerPainter(
                  pxPerSec: pxPerSec,
                  scrollX: _scrollX,
                  viewportWidth: _viewportWidth,
                  inPoint: c.inPoint?.seconds,
                  outPoint: c.outPoint?.seconds,
                ),
              ),
            ),
            for (final marker in doc.markers) _markerFlag(marker),
            ValueListenableBuilder<Rt>(
              valueListenable: c.playheadNotifier,
              builder:
                  (context, playhead, child) => Positioned(
                    left: _x(playhead) - 6,
                    bottom: 2,
                    child: child!,
                  ),
              child: IgnorePointer(
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: CcColors.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _markerFlag(Marker marker) {
    return Positioned(
      left: _x(marker.time) - 5,
      top: 2,
      child: Builder(
        builder:
            (markerContext) => GestureDetector(
              supportedDevices: _editPointerDevices,
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => c.seekTo(marker.time),
              onSecondaryTapDown:
                  (d) => showCcMenu(
                    markerContext,
                    [
                      CcMenuItem(
                        'Rename marker',
                        onTap: () => _renameMarker(marker),
                      ),
                      CcMenuItem(
                        'Delete marker',
                        danger: true,
                        onTap: () => c.removeMarker(marker.id),
                      ),
                    ],
                    position: d.globalPosition,
                  ),
              onHorizontalDragStart: (_) {
                _draggingMarkerId = marker.id;
                c.beginGesture('Move marker');
              },
              onHorizontalDragUpdate: (d) {
                if (_draggingMarkerId != marker.id) return;
                c.moveMarker(marker.id, _time(_x(marker.time) + d.delta.dx));
              },
              onHorizontalDragEnd: (_) {
                _draggingMarkerId = null;
                c.endGesture();
              },
              // A cancelled pointer must close the transaction too: an open one
              // swallows every later edit instead of letting it reach the undo
              // stack.
              onHorizontalDragCancel: () {
                _draggingMarkerId = null;
                c.endGesture();
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: CcTooltip(
                  message: marker.name.isEmpty ? 'Marker' : marker.name,
                  child: const CcIcon(
                    LucideIcons.flag,
                    size: 11,
                    color: CcColors.markerYellow,
                  ),
                ),
              ),
            ),
      ),
    );
  }

  Future<void> _renameMarker(Marker marker) async {
    final name = await promptForText(
      context,
      title: 'Rename marker',
      initialValue: marker.name,
    );
    if (name != null) c.renameMarker(marker.id, name);
  }

  Widget _inOutOverlay(double lanesHeight) {
    final inP = c.inPoint;
    final outP = c.outPoint;
    if (inP == null && outP == null) return const SizedBox.shrink();
    final left = _x(inP ?? Rt.zero());
    final right = _x(outP ?? doc.sequenceDuration);
    return Positioned(
      left: left,
      width: (right - left).clamp(0, double.infinity),
      top: 0,
      height: lanesHeight,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.symmetric(
              vertical: BorderSide(
                color: CcColors.success.withValues(alpha: 0.8),
              ),
            ),
            color: CcColors.success.withValues(alpha: 0.06),
          ),
        ),
      ),
    );
  }

  // --- Lanes ----------------------------------------------------------------

  Widget _lane(Track track) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => !track.lock,
      onMove: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(details.offset);
        setState(() {
          _dropTrackId = track.id;
          _dropSeconds = ((local.dx - TrackHeaderTile.width + _scrollX) /
                  pxPerSec)
              .clamp(0.0, double.infinity);
        });
      },
      onLeave:
          (_) => setState(() {
            _dropTrackId = null;
            _dropSeconds = null;
          }),
      onAcceptWithDetails: (details) {
        final at = Rt.fromSeconds(_dropSeconds ?? c.playhead.seconds);
        final keys = HardwareKeyboard.instance;
        final mode =
            keys.isShiftPressed
                ? DropMode.insert
                : keys.isAltPressed
                ? DropMode.append
                : DropMode.overwrite;
        setState(() {
          _dropTrackId = null;
          _dropSeconds = null;
        });
        c.placeAsset(details.data, trackId: track.id, at: at, mode: mode);
      },
      builder:
          (context, candidate, rejected) =>
              _laneContent(track, dropping: candidate.isNotEmpty),
    );
  }

  Widget _laneContent(Track track, {bool dropping = false}) {
    final (visibleFrom, visibleTo) = _visibleRange;
    final clips = doc.clipsOn(track.id);
    final visible =
        clips
            .where(
              (clip) =>
                  clip.end.seconds >= visibleFrom &&
                  clip.start.seconds <= visibleTo,
            )
            .toList();

    return SizedBox(
      height: _laneHeight(track),
      child: Stack(
        clipBehavior: ui.Clip.none,
        children: [
          Positioned.fill(child: _laneBackground(track)),
          for (final clip in visible) _clipWidget(track, clip),
          for (final tr in doc.transitions.where(
            (t) =>
                _touches(t, track.id) && _trVisible(t, visibleFrom, visibleTo),
          ))
            _transitionBadge(track, tr),
          for (var i = 0; i < clips.length - 1; i++)
            if (clips[i].end == clips[i + 1].start &&
                clips[i].end.seconds >= visibleFrom &&
                clips[i].end.seconds <= visibleTo)
              _rollHandle(track, clips[i], clips[i + 1]),
          if (dropping && _dropTrackId == track.id && _dropSeconds != null)
            _dropGhost(track),
        ],
      ),
    );
  }

  /// Ghost clip shown while a pool asset hovers a lane (TIM-5).
  Widget _dropGhost(Track track) {
    final seconds = _dropSeconds!;
    return Positioned(
      left: seconds * pxPerSec,
      width: 120,
      top: 2,
      height: _laneHeight(track) - 4,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: CcColors.accent.withValues(alpha: 0.18),
            border: Border.all(color: CcColors.accent),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Center(
            child: Text(
              HardwareKeyboard.instance.isShiftPressed
                  ? 'insert'
                  : HardwareKeyboard.instance.isAltPressed
                  ? 'append'
                  : 'overwrite',
              style: CcType.nano,
            ),
          ),
        ),
      ),
    );
  }

  Widget _laneBackground(Track track) {
    return Builder(
      builder:
          (laneContext) => GestureDetector(
            supportedDevices: _editPointerDevices,
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              c.selectClip(null);
              c.seekTo(_time(d.localPosition.dx));
            },
            // Double-click an empty stretch closes it on this lane: the
            // fastest way to remove the gap in the screenshot.
            onDoubleTapDown:
                track.lock
                    ? null
                    : (d) => c.closeGap(track.id, _time(d.localPosition.dx)),
            onPanStart: (d) {
              if (_touchPointers.length >= 2) return;
              setState(() {
                _marqueeStart = d.localPosition + Offset(0, _laneTop(track));
                _marqueeEnd = _marqueeStart;
                _marqueeAdditive = HardwareKeyboard.instance.isShiftPressed;
              });
              _noteMarqueeViewport(track, d.localPosition);
              _maybeStartMarqueeAutoscroll();
            },
            onPanUpdate: (d) {
              if (_marqueeStart == null) return;
              setState(() {
                _marqueeEnd = d.localPosition + Offset(0, _laneTop(track));
              });
              _noteMarqueeViewport(track, d.localPosition);
              _maybeStartMarqueeAutoscroll();
            },
            onPanEnd: (_) => _commitMarquee(),
            onPanCancel: _commitMarquee,
            onSecondaryTapDown:
                (d) => showCcMenu(
                  laneContext,
                  [
                    CcMenuItem(
                      'Paste',
                      shortcut: '⌘V',
                      onTap: c.hasClipboard ? c.paste : null,
                    ),
                    CcMenuItem(
                      'Add marker',
                      shortcut: 'M',
                      onTap: () => c.addMarker(),
                    ),
                    CcMenuItem(
                      'Select all',
                      shortcut: '⌘A',
                      onTap: c.selectAll,
                    ),
                    ..._gapMenuItems(track, _time(d.localPosition.dx)),
                  ],
                  position: d.globalPosition,
                ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: track.lock ? CcColors.elevated : CcColors.bg,
                border: const Border(
                  bottom: BorderSide(color: CcColors.border),
                ),
              ),
            ),
          ),
    );
  }

  /// "Close gap" entries for the lane context menu at [time]. Empty when the
  /// click landed on a clip or there is no empty space there.
  List<CcMenuItem> _gapMenuItems(Track track, Rt time) {
    if (track.lock) return const [];
    final gap = c.gapAt(track.id, time);
    if (gap == null) return const [];
    final label = _gapLabel(gap.to.minus(gap.from).seconds);
    return [
      CcMenuItem(
        'Close gap ($label)',
        separatorBefore: true,
        onTap: () => c.closeGap(track.id, time),
      ),
      CcMenuItem(
        'Close gap on all tracks ($label)',
        onTap: () => c.closeGapOnAllTracks(track.id, time),
      ),
    ];
  }

  static String _gapLabel(double seconds) {
    if (seconds < 10) {
      final text = seconds.toStringAsFixed(1);
      return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}s';
    }
    return '${seconds.round()}s';
  }

  double _laneTop(Track track) {
    var top = doc.captionTracks.length * _captionLaneHeight;
    for (final t in c.laneOrder) {
      if (t.id == track.id) break;
      top += _laneHeight(t);
    }
    return top;
  }

  void _commitMarquee() {
    _cancelMarqueeAutoscroll();
    final start = _marqueeStart;
    final end = _marqueeEnd;
    setState(() {
      _marqueeStart = null;
      _marqueeEnd = null;
    });
    if (start == null || end == null) return;
    if ((end - start).distance < 4) return;
    final lanes = c.laneOrder;
    final top = start.dy < end.dy ? start.dy : end.dy;
    final bottom = start.dy < end.dy ? end.dy : start.dy;
    final trackIds = <String>[];
    var y = doc.captionTracks.length * _captionLaneHeight;
    for (final track in lanes) {
      final laneTop = y;
      final laneBottom = y + _laneHeight(track);
      if (laneBottom > top && laneTop < bottom) trackIds.add(track.id);
      y = laneBottom;
    }
    c.selectRange(
      trackIds: trackIds,
      from: _time(start.dx),
      to: _time(end.dx),
      additive: _marqueeAdditive,
    );
  }

  Widget _marqueeBox() {
    final start = _marqueeStart!;
    final end = _marqueeEnd!;
    final rect = Rect.fromPoints(start, end);
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: CcColors.accent.withValues(alpha: 0.12),
            border: Border.all(color: CcColors.accent),
          ),
        ),
      ),
    );
  }

  Widget _emptySpace() {
    return GestureDetector(
      supportedDevices: _editPointerDevices,
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        c.selectClip(null);
        c.seekTo(_time(d.localPosition.dx));
      },
      child: const ColoredBox(color: CcColors.bg),
    );
  }

  Widget _clipWidget(Track track, Clip clip) {
    final asset = doc.assetById(clip.mediaId);
    final selected = c.selection.contains(clip.id);
    final width = (clip.duration.seconds * pxPerSec).clamp(
      2.0,
      double.infinity,
    );
    final locked = track.lock;
    // Handles shrink with the clip so a narrow tile always keeps a middle
    // third to grab for a move (TIM-6a).
    final handle = (width / 3).clamp(1.0, _kTrimHandlePx);

    Widget zone({
      required EditGesture kind,
      required MouseCursor cursor,
      required BuildContext anchorContext,
      Widget? child,
      double? width,
    }) {
      return MouseRegion(
        cursor: locked ? SystemMouseCursors.basic : cursor,
        child: GestureDetector(
          supportedDevices: _editPointerDevices,
          behavior: HitTestBehavior.opaque,
          // Wait until the gesture resolves as a tap before collapsing the
          // selection. A selected clip may be the handle for dragging the
          // whole selection, and selecting it again on pointer-down would
          // discard its peers before [beginDrag] captures their origins.
          onTap: () => _onClipTap(clip),
          onSecondaryTapDown:
              (d) => _clipMenu(anchorContext, clip, position: d.globalPosition),
          onPanStart: locked ? null : (_) => _startClipDrag(clip, kind),
          onPanUpdate:
              locked
                  ? null
                  : (d) => _updateClipDrag(
                    d,
                    lanes:
                        _dragKind == EditGesture.move
                            ? _laneDelta(track.id, _dragDelta.dy)
                            : 0,
                  ),
          onPanEnd: locked ? null : (_) => _endDrag(),
          onPanCancel: locked ? null : _endDrag,
          child: SizedBox(
            width: width,
            child: child ?? const SizedBox.expand(),
          ),
        ),
      );
    }

    return Positioned(
      left: _x(clip.start),
      width: width,
      top: 0,
      height: _laneHeight(track),
      child: Builder(
        builder:
            (clipContext) => Stack(
              children: [
                zone(
                  kind: EditGesture.move,
                  cursor: SystemMouseCursors.grab,
                  anchorContext: clipContext,
                  child: TimelineClipTile(
                    clip: clip,
                    asset: asset,
                    audio: !track.isVideo,
                    height: _laneHeight(track),
                    pxPerSec: pxPerSec,
                    selected: selected,
                    dimmed: locked || track.hidden,
                    peaks:
                        asset == null || !asset.hasAudio
                            ? const []
                            : c.waveformFor(asset),
                    tileAt:
                        asset == null || asset.type != 'video' || !track.isVideo
                            ? null
                            : (seconds) => c.filmstripTile(asset, seconds),
                    onFadeDrag:
                        locked
                            ? null
                            : (fadeIn, deltaSeconds) {
                              final current =
                                  fadeIn
                                      ? clip.fadeIn.duration
                                      : clip.fadeOut.duration;
                              c.setClipFade(
                                clip.id,
                                fadeIn: fadeIn,
                                duration: current.plus(
                                  Rt.fromSeconds(deltaSeconds),
                                ),
                              );
                            },
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: zone(
                    kind: EditGesture.trimStart,
                    cursor: SystemMouseCursors.resizeLeftRight,
                    anchorContext: clipContext,
                    width: handle,
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: zone(
                    kind: EditGesture.trimEnd,
                    cursor: SystemMouseCursors.resizeLeftRight,
                    anchorContext: clipContext,
                    width: handle,
                  ),
                ),
                // Last in the stack so a click lands on a keyframe rather than on
                // the clip body underneath it. Only tap gestures are claimed here,
                // so dragging across the ribbon still moves the clip.
                ..._keyframeRibbon(clipContext, track, clip),
              ],
            ),
      ),
    );
  }

  /// The row of diamonds marking where a clip is keyed (KEY-5), or nothing at
  /// all when it has no keyframes.
  List<Widget> _keyframeRibbon(
    BuildContext anchorContext,
    Track track,
    Clip clip,
  ) {
    if (!track.isVideo ||
        _laneHeight(track) < kKeyframeRibbonMinTrackHeight ||
        track.hidden) {
      return const [];
    }
    // The stripe is its own lane: a *tracked* clip usually has no keyframes of
    // its own, so hanging it off the keyframe ribbon would hide it exactly
    // where it is most useful.
    final weak = c.lowConfidenceSpansFor(clip);
    final stripe =
        weak.isEmpty
            ? const <Widget>[]
            : [
              Positioned(
                left: 0,
                right: 0,
                top: kKeyframeRibbonHeight,
                height: kTrackConfidenceStripeHeight,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: TrackConfidenceStripePainter(
                      spans: weak,
                      pxPerSec: pxPerSec,
                    ),
                  ),
                ),
              ),
            ];

    final markers = c.clipKeyframeMarkers(clip);
    if (markers.isEmpty) return stripe;
    final local = c.playhead.minus(clip.start);
    ClipKeyframeMarker? nearest(double dx) {
      ClipKeyframeMarker? best;
      var bestDistance = _kKeyframeHitPx;
      for (final marker in markers) {
        final distance = (marker.time.seconds * pxPerSec - dx).abs();
        if (distance <= bestDistance) {
          bestDistance = distance;
          best = marker;
        }
      }
      return best;
    }

    return [
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        height: kKeyframeRibbonHeight,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            supportedDevices: _editPointerDevices,
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final marker = nearest(d.localPosition.dx);
              _onClipTap(clip);
              if (marker != null) c.seekTo(clip.start.plus(marker.time));
            },
            onSecondaryTapDown: (d) {
              final marker = nearest(d.localPosition.dx);
              if (marker == null) {
                _clipMenu(anchorContext, clip, position: d.globalPosition);
                return;
              }
              _keyframeMarkerMenu(
                anchorContext,
                clip,
                marker,
                position: d.globalPosition,
              );
            },
            child: CustomPaint(
              painter: KeyframeRibbonPainter(
                seconds: [for (final m in markers) m.time.seconds],
                generated: [for (final m in markers) m.allGenerated],
                pxPerSec: pxPerSec,
                highlightSeconds:
                    markers
                        .firstWhereOrNull(
                          (m) =>
                              (m.time - local).micros.abs() <=
                              c.frameDuration.micros ~/ 2,
                        )
                        ?.time
                        .seconds,
              ),
            ),
          ),
        ),
      ),
      ...stripe,
    ];
  }

  /// Right-click on one of those diamonds: jump to it, delete it, or — when a
  /// preset wrote it — say why it cannot be deleted on its own.
  void _keyframeMarkerMenu(
    BuildContext anchorContext,
    Clip clip,
    ClipKeyframeMarker marker, {
    Offset? position,
  }) {
    if (!c.selection.contains(clip.id)) c.selectClip(clip.id);
    final params = marker.keys.map((k) => k.label).toSet().toList()..sort();
    final deletable = marker.keys.where((k) => !k.generated).length;
    showCcMenu(
      anchorContext,
      [
      CcMenuItem(
        params.length == 1 ? params.first : '${params.length} parameters',
        onTap: null,
      ),
      CcMenuItem(
        'Go to keyframe',
        icon: LucideIcons.crosshair,
        onTap: () => c.seekTo(clip.start.plus(marker.time)),
      ),
      CcMenuItem(
        marker.allGenerated
            ? 'From clip animation. Clear the preset'
            : deletable == 1
            ? 'Delete keyframe'
            : 'Delete $deletable keyframes here',
        icon: LucideIcons.trash2,
        separatorBefore: true,
        danger: !marker.allGenerated,
        onTap:
            marker.allGenerated
                ? null
                : () => c.removeKeyframesAt(clip.id, marker.time),
      ),
      CcMenuItem(
        'Clear all keyframes on clip',
        danger: true,
        onTap: () => c.clearAllKeyframes(clip.id),
      ),
      ],
      position: position,
    );
  }

  bool _touches(Transition t, String trackId) =>
      doc.clipById(t.aClipId)?.trackId == trackId;

  bool _trVisible(Transition t, double from, double to) {
    final a = doc.clipById(t.aClipId);
    final b = doc.clipById(t.bClipId);
    if (a == null || b == null) return false;
    final end = a.end > b.end ? a.end : b.end;
    return end.seconds >= from && b.start.seconds <= to;
  }

  /// Hourglass badge straddling the overlap; drag edges to retime (TRA-6),
  /// click to select, right-click for type/alignment/delete.
  Widget _transitionBadge(Track track, Transition tr) {
    final a = doc.clipById(tr.aClipId);
    final b = doc.clipById(tr.bClipId);
    if (a == null || b == null) return const SizedBox.shrink();
    final start = a.start > b.start ? b.start : a.start;
    final width =
        ((a.end > b.end ? b.end : a.end).minus(start)).seconds * pxPerSec;
    return Positioned(
      left: start.seconds * pxPerSec,
      width: width.clamp(10, double.infinity),
      top: 2,
      height: _laneHeight(track) - 4,
      child: Builder(
        builder:
            (badgeContext) => GestureDetector(
              supportedDevices: _editPointerDevices,
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => c.selectClip(null),
              onHorizontalDragStart: (_) => c.beginGesture('Retime transition'),
              onHorizontalDragUpdate:
                  (d) => c.setTransitionDurationLive(
                    tr.id,
                    tr.duration.plus(Rt.fromSeconds(d.delta.dx / pxPerSec)),
                  ),
              onHorizontalDragEnd: (_) => c.endGesture(),
              onHorizontalDragCancel: () => c.endGesture(),
              onSecondaryTapDown:
                  (d) => _transitionMenu(
                    badgeContext,
                    tr,
                    position: d.globalPosition,
                  ),
              child: CcTooltip(
                message:
                    '${tr.type} · ${tr.duration.seconds.toStringAsFixed(2)}s',
                child: const TransitionBadge(height: 20),
              ),
            ),
      ),
    );
  }

  void _transitionMenu(
    BuildContext anchorContext,
    Transition tr, {
    Offset? position,
  }) {
    showCcMenu(
      anchorContext,
      [
      const CcMenuItem('Type', onTap: null),
      CcMenuItem(
        'Cross dissolve',
        checked: tr.type == 'crossDissolve',
        onTap: () => c.setTransitionType(tr.id, 'crossDissolve'),
      ),
      CcMenuItem(
        'Dip to black',
        checked: tr.type == 'dipToBlack',
        onTap: () => c.setTransitionType(tr.id, 'dipToBlack'),
      ),
      CcMenuItem(
        'Dip to white',
        checked: tr.type == 'dipToWhite',
        onTap: () => c.setTransitionType(tr.id, 'dipToWhite'),
      ),
      CcMenuItem(
        'Push left',
        checked: tr.type == 'pushLeft',
        onTap: () => c.setTransitionType(tr.id, 'pushLeft'),
      ),
      CcMenuItem(
        'Zoom in',
        checked: tr.type == 'zoomIn',
        onTap: () => c.setTransitionType(tr.id, 'zoomIn'),
      ),
      const CcMenuItem('Alignment', onTap: null),
      CcMenuItem(
        'Center',
        checked: tr.alignment == 'center',
        onTap: () => c.setTransitionAlignment(tr.id, 'center'),
      ),
      CcMenuItem(
        'Start',
        checked: tr.alignment == 'start',
        onTap: () => c.setTransitionAlignment(tr.id, 'start'),
      ),
      CcMenuItem(
        'End',
        checked: tr.alignment == 'end',
        onTap: () => c.setTransitionAlignment(tr.id, 'end'),
      ),
      CcMenuItem(
        'Remove transition',
        danger: true,
        onTap: () => c.removeTransition(tr.id),
      ),
      ],
      position: position,
    );
  }

  /// Straddles a cut: dragging it rolls both sides (TIM-6).
  Widget _rollHandle(Track track, Clip left, Clip right) {
    return Positioned(
      left: _x(left.end) - 5,
      width: 10,
      top: 0,
      height: _laneHeight(track),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          supportedDevices: _editPointerDevices,
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            _dragDelta = Offset.zero;
            _dragging = true;
            c.beginRoll(left.id, right.id);
          },
          onPanUpdate: (d) => _updateClipDrag(d),
          onPanEnd: (_) => _endDrag(),
          onPanCancel: _endDrag,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
