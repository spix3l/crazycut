import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/cc_dialog.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../../../../data/project.dart';
import '../../../../../data/transition.dart';
import '../../../../../models/rational.dart';
import '../../../../../state/editor_controller.dart';
import '../../../../../state/timeline_edits.dart';
import '../../models/editor_models.dart';
import 'timeline_clip_tile.dart';
import 'track_header.dart';

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

  @override
  State<TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends State<TimelinePanel> {
  final _headerScroll = ScrollController();
  final _laneScroll = ScrollController();
  final _horizontal = ScrollController();
  bool _syncing = false;

  double _scrollX = 0;
  double _viewportWidth = 800;

  // Drag bookkeeping in pixels; the controller works from gesture origins.
  Offset _dragDelta = Offset.zero;
  bool _dragging = false;
  double? _zoomAnchorSeconds;
  Offset? _marqueeStart;
  Offset? _marqueeEnd;
  bool _marqueeAdditive = false;
  String? _dropTrackId;
  double? _dropSeconds;
  String? _draggingMarkerId;

  EditorController get c => widget.controller;
  ProjectDoc get doc => c.doc;
  double get pxPerSec => widget.pxPerSec;

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
    to.jumpTo(from.offset.clamp(to.position.minScrollExtent, to.position.maxScrollExtent));
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
    final pointerOffset = anchor == null ? 0.0 : anchor * oldWidget.pxPerSec - _scrollX;
    final target = anchor == null
        ? _scrollX * widget.pxPerSec / oldWidget.pxPerSec
        : anchor * widget.pxPerSec - pointerOffset;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_horizontal.hasClients) return;
      _horizontal.jumpTo(target.clamp(0.0, _horizontal.position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    _headerScroll.dispose();
    _laneScroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  // --- Geometry -------------------------------------------------------------

  double _x(Rt t) => t.seconds * pxPerSec;
  Rt _time(double x) => Rt.fromSeconds((x / pxPerSec).clamp(0, double.infinity));

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
      EditGesture.move when keys.isAltPressed && !keys.isMetaPressed => EditGesture.slip,
      EditGesture.move when keys.isMetaPressed => EditGesture.slide,
      _ => fallback,
    };
    _dragDelta = Offset.zero;
    _dragging = true;
    c.beginDrag(kind, clip.id, breakLinks: keys.isAltPressed && kind == EditGesture.move);
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
    c.endGesture();
  }

  /// How many lanes a vertical drag crossed, from the lane heights.
  int _laneDelta(String fromTrackId, double dy) {
    final lanes = c.laneOrder;
    var index = lanes.indexWhere((t) => t.id == fromTrackId);
    if (index < 0) return 0;
    final start = index;
    var remaining = dy;
    while (remaining > 0 && index < lanes.length - 1) {
      final step = lanes[index].height.toDouble();
      if (remaining < step / 2) break;
      remaining -= step;
      index++;
    }
    while (remaining < 0 && index > 0) {
      final step = lanes[index - 1].height.toDouble();
      if (-remaining < step / 2) break;
      remaining += step;
      index--;
    }
    return index - start;
  }

  void _clipMenu(BuildContext context, Offset position, Clip clip) {
    if (!c.selection.contains(clip.id)) c.selectClip(clip.id);
    final linked = clip.linkedGroup != null;
    final isImage = c.doc.assetById(clip.mediaId)?.type == 'image';
    showCcMenu(context, position, [
      CcMenuItem('Split at playhead', shortcut: 'S', onTap: c.splitAtPlayhead),
      CcMenuItem('Copy', shortcut: '⌘C', onTap: c.copySelection),
      CcMenuItem('Cut', shortcut: '⌘X', onTap: c.cutSelection),
      CcMenuItem('Delete', shortcut: '⌫', onTap: () => c.deleteSelected(ripple: false)),
      CcMenuItem('Ripple delete', shortcut: '⇧⌫', onTap: () => c.deleteSelected(ripple: true)),
      CcMenuItem(
        linked ? 'Unlink A/V' : 'Link selection',
        separatorBefore: true,
        onTap: linked ? c.unlinkSelection : (c.selection.length > 1 ? c.linkSelection : null),
      ),
      CcMenuItem(
        clip.mute ? 'Unmute clip' : 'Mute clip',
        onTap: () => c.setClipAudio(clip.id, mute: !clip.mute),
      ),
      if (isImage)
        for (final preset in TimelineEdits.kImagePresets.entries)
          CcMenuItem(
            'Animate: ${preset.key}',
            separatorBefore: preset.key == TimelineEdits.kImagePresets.keys.first,
            checked: c.imageAnimPreset(clip, 'motion') == preset.value,
            onTap: () => c.applyImagePreset(clip.id, preset.value),
          ),
      if (isImage)
        for (final preset in TimelineEdits.kImageEntryPresets.entries)
          CcMenuItem(
            'Appear: ${preset.key}',
            separatorBefore:
                preset.key == TimelineEdits.kImageEntryPresets.keys.first,
            checked: c.imageAnimPreset(clip, 'in') == preset.value,
            onTap: () => c.setImageEntryExit(clip.id, appear: preset.value),
          ),
      if (isImage)
        for (final preset in TimelineEdits.kImageEntryPresets.entries)
          CcMenuItem(
            'Disappear: ${preset.key}',
            separatorBefore:
                preset.key == TimelineEdits.kImageEntryPresets.keys.first,
            checked: c.imageAnimPreset(clip, 'out') == preset.value,
            onTap: () => c.setImageEntryExit(clip.id, disappear: preset.value),
          ),
      if (isImage)
        CcMenuItem(
          'Clear image animation',
          separatorBefore: true,
          onTap: () => c.clearImageAnimation(clip.id),
        ),
    ]);
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final lanes = c.laneOrder;
    final lanesHeight = lanes.fold<double>(0, (sum, t) => sum + t.height);

    return Container(
      decoration: const BoxDecoration(color: CcColors.panel, border: CcBorders.top),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TimelineToolbar(
            controller: c,
            snap: widget.snap,
            zoom: (pxPerSec - kMinPxPerSec) / (kMaxPxPerSec - kMinPxPerSec),
            onSnapChanged: widget.onSnapChanged,
            onZoomChanged: widget.onZoomChanged,
            onFit: widget.onFit,
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
                          child: Column(children: [for (final track in lanes) _header(track)]),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _viewportWidth = constraints.maxWidth;
                      return Listener(
                        onPointerSignal: _onPointerSignal,
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
                                      height: lanesHeight < constraints.maxHeight
                                          ? constraints.maxHeight - TimelinePanel.rulerHeight
                                          : lanesHeight,
                                      child: Stack(
                                        clipBehavior: ui.Clip.none,
                                        children: [
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              for (final track in lanes) _lane(track),
                                              Expanded(child: _emptySpace()),
                                            ],
                                          ),
                                          if (doc.clips.isEmpty)
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
                                                  child: ColoredBox(color: CcColors.warning),
                                                ),
                                              ),
                                            ),
                                          Positioned(
                                            left: _x(c.playhead) - 1,
                                            top: 0,
                                            height: lanesHeight,
                                            child: const IgnorePointer(
                                              child: SizedBox(
                                                width: 2,
                                                child: ColoredBox(color: CcColors.accent),
                                              ),
                                            ),
                                          ),
                                          if (_marqueeStart != null && _marqueeEnd != null)
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

  Widget _header(Track track) {
    return TrackHeaderTile(
      track: track,
      selected: doc.clipsOn(track.id).any((clip) => c.selection.contains(clip.id)),
      onSelect: () =>
          c.selectTrack(track.id, additive: HardwareKeyboard.instance.isShiftPressed),
      onRename: (name) => c.renameTrack(track.id, name),
      onToggleMute: () => c.setTrackFlags(track.id, mute: !track.mute),
      onToggleSolo: () => c.setTrackFlags(track.id, solo: !track.solo),
      onToggleHidden: () => c.setTrackFlags(track.id, hidden: !track.hidden),
      onToggleLock: () => c.setTrackFlags(track.id, lock: !track.lock),
      onCycleHeight: () {
        const order = TrackHeight.values;
        final current = TrackHeight.nearest(track.height);
        c.setTrackHeight(track.id, order[(order.indexOf(current) + 1) % order.length]);
      },
      onReorder: (delta) => c.reorderTrack(track.id, delta),
      onRemove: () => c.removeTrack(track.id),
    );
  }

  // --- Ruler ----------------------------------------------------------------

  Widget _ruler() {
    return GestureDetector(
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
            Positioned(
              left: _x(c.playhead) - 6,
              bottom: 2,
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => c.seekTo(marker.time),
        onSecondaryTapDown: (d) => showCcMenu(context, d.globalPosition, [
          CcMenuItem('Rename marker', onTap: () => _renameMarker(marker)),
          CcMenuItem('Delete marker', danger: true, onTap: () => c.removeMarker(marker.id)),
        ]),
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
            child: const CcIcon(LucideIcons.flag, size: 11, color: CcColors.markerYellow),
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
              vertical: BorderSide(color: CcColors.success.withValues(alpha: 0.8)),
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
          _dropSeconds = ((local.dx - TrackHeaderTile.width + _scrollX) / pxPerSec).clamp(
            0.0,
            double.infinity,
          );
        });
      },
      onLeave: (_) => setState(() {
        _dropTrackId = null;
        _dropSeconds = null;
      }),
      onAcceptWithDetails: (details) {
        final at = Rt.fromSeconds(_dropSeconds ?? c.playhead.seconds);
        final keys = HardwareKeyboard.instance;
        final mode = keys.isShiftPressed
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
      builder: (context, candidate, rejected) =>
          _laneContent(track, dropping: candidate.isNotEmpty),
    );
  }

  Widget _laneContent(Track track, {bool dropping = false}) {
    final (visibleFrom, visibleTo) = _visibleRange;
    final clips = doc.clipsOn(track.id);
    final visible = clips
        .where((clip) => clip.end.seconds >= visibleFrom && clip.start.seconds <= visibleTo)
        .toList();

    return SizedBox(
      height: track.height.toDouble(),
      child: Stack(
        clipBehavior: ui.Clip.none,
        children: [
          Positioned.fill(child: _laneBackground(track)),
          for (final clip in visible) _clipWidget(track, clip),
          for (final tr in doc.transitions.where(
            (t) => _touches(t, track.id) && _trVisible(t, visibleFrom, visibleTo),
          ))
            _transitionBadge(track, tr),
          for (var i = 0; i < clips.length - 1; i++)
            if (clips[i].end == clips[i + 1].start &&
                clips[i].end.seconds >= visibleFrom &&
                clips[i].end.seconds <= visibleTo)
              _rollHandle(track, clips[i], clips[i + 1]),
          if (dropping && _dropTrackId == track.id && _dropSeconds != null) _dropGhost(track),
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
      height: track.height - 4,
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        c.selectClip(null);
        c.seekTo(_time(d.localPosition.dx));
      },
      onPanStart: (d) => setState(() {
        _marqueeStart = d.localPosition + Offset(0, _laneTop(track));
        _marqueeEnd = _marqueeStart;
        _marqueeAdditive = HardwareKeyboard.instance.isShiftPressed;
      }),
      onPanUpdate: (d) => setState(() {
        _marqueeEnd = d.localPosition + Offset(0, _laneTop(track));
      }),
      onPanEnd: (_) => _commitMarquee(),
      onPanCancel: _commitMarquee,
      onSecondaryTapDown: (d) => showCcMenu(context, d.globalPosition, [
        CcMenuItem('Paste', shortcut: '⌘V', onTap: c.hasClipboard ? c.paste : null),
        CcMenuItem('Add marker', shortcut: 'M', onTap: () => c.addMarker()),
        CcMenuItem('Select all', shortcut: '⌘A', onTap: c.selectAll),
      ]),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: track.lock ? CcColors.elevated : CcColors.bg,
          border: const Border(bottom: BorderSide(color: CcColors.border)),
        ),
      ),
    );
  }

  double _laneTop(Track track) {
    var top = 0.0;
    for (final t in c.laneOrder) {
      if (t.id == track.id) break;
      top += t.height;
    }
    return top;
  }

  void _commitMarquee() {
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
    var y = 0.0;
    for (final track in lanes) {
      final laneTop = y;
      final laneBottom = y + track.height;
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
    final width = (clip.duration.seconds * pxPerSec).clamp(2.0, double.infinity);
    final locked = track.lock;

    Widget zone({
      required EditGesture kind,
      required MouseCursor cursor,
      Widget? child,
      double? width,
    }) {
      return MouseRegion(
        cursor: locked ? SystemMouseCursors.basic : cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _onClipTap(clip),
          onSecondaryTapDown: (d) => _clipMenu(context, d.globalPosition, clip),
          onPanStart: locked ? null : (_) => _startClipDrag(clip, kind),
          onPanUpdate: locked
              ? null
              : (d) => _updateClipDrag(
                  d,
                  lanes: kind == EditGesture.move ? _laneDelta(track.id, _dragDelta.dy) : 0,
                ),
          onPanEnd: locked ? null : (_) => _endDrag(),
          onPanCancel: locked ? null : _endDrag,
          child: SizedBox(width: width, child: child ?? const SizedBox.expand()),
        ),
      );
    }

    return Positioned(
      left: _x(clip.start),
      width: width,
      top: 0,
      height: track.height.toDouble(),
      child: Stack(
        children: [
          zone(
            kind: EditGesture.move,
            cursor: SystemMouseCursors.grab,
            child: TimelineClipTile(
              clip: clip,
              asset: asset,
              audio: !track.isVideo,
              height: track.height.toDouble(),
              pxPerSec: pxPerSec,
              selected: selected,
              dimmed: locked || track.hidden,
              peaks: asset == null || !asset.hasAudio ? const [] : c.waveformFor(asset),
              tileAt: asset == null || asset.type != 'video' || !track.isVideo
                  ? null
                  : (seconds) => c.filmstripTile(asset, seconds),
              onFadeDrag: locked
                  ? null
                  : (fadeIn, deltaSeconds) {
                      final current = fadeIn ? clip.fadeIn.duration : clip.fadeOut.duration;
                      c.setClipFade(
                        clip.id,
                        fadeIn: fadeIn,
                        duration: current.plus(Rt.fromSeconds(deltaSeconds)),
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
              width: 7,
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: zone(
              kind: EditGesture.trimEnd,
              cursor: SystemMouseCursors.resizeLeftRight,
              width: 7,
            ),
          ),
        ],
      ),
    );
  }

  bool _touches(Transition t, String trackId) => doc.clipById(t.aClipId)?.trackId == trackId;

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
    final width = ((a.end > b.end ? b.end : a.end).minus(start)).seconds * pxPerSec;
    return Positioned(
      left: start.seconds * pxPerSec,
      width: width.clamp(10, double.infinity),
      top: 2,
      height: track.height - 4,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => c.selectClip(null),
        onHorizontalDragStart: (_) => c.beginGesture('Retime transition'),
        onHorizontalDragUpdate: (d) => c.setTransitionDurationLive(
          tr.id,
          tr.duration.plus(Rt.fromSeconds(d.delta.dx / pxPerSec)),
        ),
        onHorizontalDragEnd: (_) => c.endGesture(),
        onHorizontalDragCancel: () => c.endGesture(),
        onSecondaryTapDown: (d) => _transitionMenu(context, d.globalPosition, tr),
        child: CcTooltip(
          message: '${tr.type} · ${tr.duration.seconds.toStringAsFixed(2)}s',
          child: const TransitionBadge(height: 20),
        ),
      ),
    );
  }

  void _transitionMenu(BuildContext context, Offset at, Transition tr) {
    showCcMenu(context, at, [
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
      CcMenuItem('Remove transition', danger: true, onTap: () => c.removeTransition(tr.id)),
    ]);
  }

  /// Straddles a cut: dragging it rolls both sides (TIM-6).
  Widget _rollHandle(Track track, Clip left, Clip right) {
    return Positioned(
      left: _x(left.end) - 5,
      width: 10,
      top: 0,
      height: track.height.toDouble(),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
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

/// Ruler ticks and the in/out band. Painted rather than composed so a long
/// sequence does not build thousands of widgets (TIM-22).
class RulerPainter extends CustomPainter {
  const RulerPainter({
    required this.pxPerSec,
    required this.scrollX,
    required this.viewportWidth,
    this.inPoint,
    this.outPoint,
  });

  static const _ladder = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600];

  final double pxPerSec;
  final double scrollX;
  final double viewportWidth;
  final double? inPoint;
  final double? outPoint;

  /// Smallest interval that leaves ≥ 64 px between labels.
  double get step =>
      _ladder.firstWhere((s) => s * pxPerSec >= 64, orElse: () => _ladder.last).toDouble();

  static String label(double seconds) {
    final total = seconds.round();
    final m = total ~/ 60;
    final s = total % 60;
    if (seconds > 0 && seconds < 1) return '${seconds.toStringAsFixed(1)}s';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  void paint(Canvas canvas, Size size) {
    final tickPaint = Paint()..color = CcColors.borderStrong;
    final from = ((scrollX - 100) / pxPerSec).clamp(0.0, double.infinity);
    final to = (scrollX + viewportWidth + 100) / pxPerSec;

    if (inPoint != null || outPoint != null) {
      final left = (inPoint ?? 0) * pxPerSec;
      final right = (outPoint ?? to) * pxPerSec;
      canvas.drawRect(
        Rect.fromLTRB(left, size.height - 4, right, size.height),
        Paint()..color = CcColors.success,
      );
    }

    var t = (from / step).floor() * step;
    while (t <= to) {
      final x = t * pxPerSec;
      canvas.drawRect(Rect.fromLTWH(x, size.height - 8, 1, 8), tickPaint);
      final painter = TextPainter(
        text: TextSpan(text: label(t), style: CcType.nano),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset(x + 4, 4));
      t += step;
    }
  }

  @override
  bool shouldRepaint(RulerPainter old) =>
      old.pxPerSec != pxPerSec ||
      old.scrollX != scrollX ||
      old.viewportWidth != viewportWidth ||
      old.inPoint != inPoint ||
      old.outPoint != outPoint;
}

class _TimelineToolbar extends StatelessWidget {
  const _TimelineToolbar({
    required this.controller,
    required this.snap,
    required this.zoom,
    this.onSnapChanged,
    this.onZoomChanged,
    this.onFit,
  });

  final EditorController controller;
  final bool snap;
  final double zoom;
  final ValueChanged<bool>? onSnapChanged;
  final ValueChanged<double>? onZoomChanged;
  final VoidCallback? onFit;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final hasSelection = c.selection.isNotEmpty;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(border: CcBorders.bottom),
      child: Row(
        children: [
          _ToolIcon(
            icon: LucideIcons.scissors,
            tooltip: 'Split at playhead (S)',
            onTap: c.splitAtPlayhead,
          ),
          _ToolIcon(
            icon: LucideIcons.trash2,
            tooltip: 'Delete (⌫) · ripple with ⇧',
            enabled: hasSelection,
            onTap: () => c.deleteSelected(),
          ),
          _ToolIcon(
            icon: LucideIcons.flag,
            tooltip: 'Add marker (M)',
            onTap: () => c.addMarker(),
          ),
          _ToolIcon(
            icon: LucideIcons.link,
            tooltip: 'Link selection',
            enabled: c.selection.length > 1,
            onTap: c.linkSelection,
          ),
          _ToolIcon(
            icon: c.linkAudioOnAdd ? LucideIcons.link2 : LucideIcons.link2Off,
            tooltip: c.linkAudioOnAdd
                ? 'Adding a video also lays down its linked audio. Click for picture only'
                : 'Videos are added as picture only. Click to also lay down linked audio',
            active: c.linkAudioOnAdd,
            onTap: () => c.setLinkAudioOnAdd(!c.linkAudioOnAdd),
          ),
          _ToolIcon(
            icon: LucideIcons.magnet,
            tooltip: 'Snapping (hold ⌃ to bypass)',
            active: snap,
            onTap: onSnapChanged == null ? null : () => onSnapChanged!(!snap),
          ),
          _ToolIcon(
            icon: LucideIcons.combine,
            tooltip: 'Magnetic timeline (deletes close gaps)',
            active: c.magnetic,
            onTap: () => c.setMagnetic(!c.magnetic),
          ),
          const SizedBox(width: 8),
          const CcDivider(height: 16),
          const SizedBox(width: 8),
          CcTappable(
            onTap: () => c.addTrack('video'),
            child: Text(
              '+ Video',
              style: CcType.style(size: 11, color: CcColors.textSecondary),
            ),
          ),
          const SizedBox(width: 10),
          CcTappable(
            onTap: () => c.addTrack('audio'),
            child: Text(
              '+ Audio',
              style: CcType.style(size: 11, color: CcColors.textSecondary),
            ),
          ),
          const Spacer(),
          if (c.trimFeedback != null) ...[
            Text(
              c.trimFeedback!,
              style: CcType.style(
                size: 11,
                weight: CcType.medium,
                color: c.trimAtLimit ? CcColors.warning : CcColors.textSecondary,
              ),
            ),
            const SizedBox(width: 12),
          ],
          _ToolIcon(
            icon: LucideIcons.zoomOut,
            tooltip: 'Zoom out (⌘−)',
            onTap: onZoomChanged == null
                ? null
                : () => onZoomChanged!((zoom - 0.1).clamp(0, 1)),
          ),
          SizedBox(
            width: 80,
            child: CcSlider(
              value: zoom.clamp(0, 1),
              trackHeight: 3,
              handleSize: 9,
              onChanged: onZoomChanged,
            ),
          ),
          _ToolIcon(
            icon: LucideIcons.zoomIn,
            tooltip: 'Zoom in (⌘+)',
            onTap: onZoomChanged == null
                ? null
                : () => onZoomChanged!((zoom + 0.1).clamp(0, 1)),
          ),
          _ToolIcon(icon: LucideIcons.scan, tooltip: 'Zoom to fit (\\)', onTap: onFit),
        ],
      ),
    );
  }
}

class _ToolIcon extends StatelessWidget {
  const _ToolIcon({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.active = false,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: CcTooltip(
        message: tooltip,
        child: CcTappable(
          onTap: enabled ? onTap : null,
          child: CcIcon(
            icon,
            size: 14,
            color: !enabled
                ? CcColors.textTertiary
                : active
                ? CcColors.accent
                : CcColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Two-step nudge shown over the empty lanes of a fresh project.
class _GettingStartedHint extends StatelessWidget {
  const _GettingStartedHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          _HintStep(number: '1', label: 'Import your rushes', active: true),
          SizedBox(width: 10),
          CcIcon(LucideIcons.arrowRight, size: 14, color: CcColors.textTertiary),
          SizedBox(width: 10),
          _HintStep(number: '2', label: 'Drag them onto the timeline', active: false),
        ],
      ),
    );
  }
}

class _HintStep extends StatelessWidget {
  const _HintStep({required this.number, required this.label, required this.active});

  final String number;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brMd,
        border: CcBorders.allStrong,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? CcColors.accent : CcColors.elevated2,
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: CcType.style(
                size: 11,
                weight: CcType.bold,
                color: active ? CcColors.onAccent : CcColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: CcType.style(
              size: 12,
              weight: CcType.medium,
              color: active ? CcColors.textPrimary : CcColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
