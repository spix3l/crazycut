import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import '../../models/editor_models.dart';
import 'timeline_clip_tile.dart';
import 'track_header.dart';

/// Zoom range: 8 px/s (≈3 minutes across a 1440 px viewport) up to 160 px/s
/// (about 5 px per frame at 30 fps).
const double kMinPxPerSec = 8;
const double kMaxPxPerSec = 160;

/// Width of the grab zones on a clip's head and tail.
const double _kTrimHandle = 7;

enum _DragMode { move, trimStart, trimEnd }

class _Drag {
  _Drag({
    required this.clipId,
    required this.mode,
    required this.originStart,
    required this.originEnd,
    required this.originTrackIndex,
  });

  final String clipId;
  final _DragMode mode;
  final double originStart;
  final double originEnd;
  final int originTrackIndex;
  double dx = 0;
  double dy = 0;
}

/// Bottom half of the editor: tool strip, ruler, track headers, lanes and the
/// playhead. All document mutations leave through the callbacks — the panel
/// only turns pixels into seconds.
class TimelinePanel extends StatefulWidget {
  const TimelinePanel({
    super.key,
    required this.tracks,
    this.playheadSeconds = 0,
    this.durationSeconds = 36,
    this.pxPerSec = kPixelsPerSecond,
    this.markers = const [],
    this.snapIndicatorSeconds,
    this.showGettingStartedHint = false,
    this.selectedClipId,
    this.onSelect,
    this.onScrub,
    this.onGestureBegin,
    this.onGestureEnd,
    this.onMove,
    this.onTrimStart,
    this.onTrimEnd,
    this.onSplit,
    this.onDelete,
    this.onAddMarker,
    this.onAddTrack,
    this.snap = true,
    this.onSnapChanged,
    this.onZoomChanged,
    this.onFit,
  });

  static const double rulerHeight = 24;

  final List<TimelineTrack> tracks;
  final double playheadSeconds;
  final double durationSeconds;

  /// Horizontal zoom, in pixels per second.
  final double pxPerSec;
  final List<TimelineMarker> markers;

  /// Where the snap indicator line goes while a drag is locked on.
  final double? snapIndicatorSeconds;
  final bool showGettingStartedHint;

  final String? selectedClipId;
  final ValueChanged<String?>? onSelect;

  /// Playhead scrub, in seconds from the sequence origin.
  final ValueChanged<double>? onScrub;

  /// Opens/closes an undo-coalescing window around a drag.
  final VoidCallback? onGestureBegin;
  final VoidCallback? onGestureEnd;

  /// (clipId, targetTrackId, newStartSeconds)
  final void Function(String clipId, String trackId, double start)? onMove;
  final void Function(String clipId, double startSeconds)? onTrimStart;
  final void Function(String clipId, double endSeconds)? onTrimEnd;

  final VoidCallback? onSplit;

  /// Ripple when the caller asks for it (Shift+Delete).
  final void Function({required bool ripple})? onDelete;
  final VoidCallback? onAddMarker;
  final ValueChanged<String>? onAddTrack;

  final bool snap;
  final ValueChanged<bool>? onSnapChanged;
  final ValueChanged<double>? onZoomChanged;
  final VoidCallback? onFit;

  @override
  State<TimelinePanel> createState() => _TimelinePanelState();
}

class _TimelinePanelState extends State<TimelinePanel> {
  final _headerScroll = ScrollController();
  final _laneScroll = ScrollController();
  final _horizontal = ScrollController();
  bool _syncing = false;
  _Drag? _drag;

  @override
  void initState() {
    super.initState();
    _headerScroll.addListener(() => _mirror(_headerScroll, _laneScroll));
    _laneScroll.addListener(() => _mirror(_laneScroll, _headerScroll));
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
  void dispose() {
    _headerScroll.dispose();
    _laneScroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  double get _pxPerSec => widget.pxPerSec;

  double _seconds(double dx) => dx / _pxPerSec;

  /// Which lane a vertical drag delta lands on, given where it started.
  int _laneAt(int originIndex, double dy) {
    var index = originIndex;
    var remaining = dy;
    while (remaining > 0 && index < widget.tracks.length - 1) {
      final step = widget.tracks[index].height;
      if (remaining < step / 2) break;
      remaining -= step;
      index++;
    }
    while (remaining < 0 && index > 0) {
      final step = widget.tracks[index - 1].height;
      if (-remaining < step / 2) break;
      remaining += step;
      index--;
    }
    return index;
  }

  void _startDrag(TimelineClip clip, int trackIndex, _DragMode mode) {
    if (clip.id == null) return;
    widget.onGestureBegin?.call();
    _drag = _Drag(
      clipId: clip.id!,
      mode: mode,
      originStart: clip.start,
      originEnd: clip.end,
      originTrackIndex: trackIndex,
    );
  }

  void _updateDrag(DragUpdateDetails details) {
    final drag = _drag;
    if (drag == null) return;
    drag.dx += details.delta.dx;
    drag.dy += details.delta.dy;
    switch (drag.mode) {
      case _DragMode.move:
        final lane = _laneAt(drag.originTrackIndex, drag.dy);
        final trackId = widget.tracks[lane].id;
        if (trackId == null) return;
        widget.onMove?.call(drag.clipId, trackId, drag.originStart + _seconds(drag.dx));
      case _DragMode.trimStart:
        widget.onTrimStart?.call(drag.clipId, drag.originStart + _seconds(drag.dx));
      case _DragMode.trimEnd:
        widget.onTrimEnd?.call(drag.clipId, drag.originEnd + _seconds(drag.dx));
    }
  }

  void _endDrag() {
    if (_drag == null) return;
    _drag = null;
    widget.onGestureEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final lanesHeight = widget.tracks.fold<double>(0, (sum, t) => sum + t.height);

    return Container(
      decoration: const BoxDecoration(color: CcColors.panel, border: CcBorders.top),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TimelineToolbar(
            canDelete: widget.selectedClipId != null,
            snap: widget.snap,
            zoom: (widget.pxPerSec - kMinPxPerSec) / (kMaxPxPerSec - kMinPxPerSec),
            onSplit: widget.onSplit,
            onDelete: widget.onDelete,
            onAddMarker: widget.onAddMarker,
            onAddTrack: widget.onAddTrack,
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
                          child: Column(
                            children: [
                              for (final track in widget.tracks) TrackHeaderTile(track: track),
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
                      final contentWidth = ((widget.durationSeconds + 4) * _pxPerSec).clamp(
                        constraints.maxWidth,
                        double.infinity,
                      );
                      return SingleChildScrollView(
                        controller: _horizontal,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: contentWidth,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _ScrubArea(
                                pxPerSec: _pxPerSec,
                                duration: widget.durationSeconds,
                                onScrub: widget.onScrub,
                                child: TimelineRuler(
                                  width: contentWidth,
                                  durationSeconds: widget.durationSeconds,
                                  pxPerSec: _pxPerSec,
                                  markers: widget.markers,
                                  playheadSeconds: widget.playheadSeconds,
                                ),
                              ),
                              Expanded(
                                child: SingleChildScrollView(
                                  controller: _laneScroll,
                                  child: SizedBox(
                                    height: lanesHeight,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        _ScrubArea(
                                          pxPerSec: _pxPerSec,
                                          duration: widget.durationSeconds,
                                          dragToScrub: false,
                                          onScrub: (seconds) {
                                            widget.onSelect?.call(null);
                                            widget.onScrub?.call(seconds);
                                          },
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              for (var i = 0; i < widget.tracks.length; i++)
                                                _Lane(
                                                  track: widget.tracks[i],
                                                  index: i,
                                                  pxPerSec: _pxPerSec,
                                                  selectedClipId: widget.selectedClipId,
                                                  onSelect: widget.onSelect,
                                                  onDragStart: _startDrag,
                                                  onDragUpdate: _updateDrag,
                                                  onDragEnd: _endDrag,
                                                ),
                                            ],
                                          ),
                                        ),
                                        if (widget.showGettingStartedHint)
                                          Positioned(
                                            left: 0,
                                            top: 0,
                                            width: constraints.maxWidth,
                                            height: lanesHeight,
                                            child: const IgnorePointer(
                                              child: _GettingStartedHint(),
                                            ),
                                          ),
                                        if (widget.snapIndicatorSeconds != null)
                                          Positioned(
                                            left: widget.snapIndicatorSeconds! * _pxPerSec,
                                            top: 0,
                                            height: lanesHeight,
                                            child: const IgnorePointer(child: _SnapLine()),
                                          ),
                                        Positioned(
                                          left: widget.playheadSeconds * _pxPerSec - 1,
                                          top: 0,
                                          height: lanesHeight,
                                          child: const IgnorePointer(
                                            child: SizedBox(
                                              width: 2,
                                              child: ColoredBox(color: CcColors.accent),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
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
}

/// Transparent hit layer that turns taps and drags into playhead seeks.
class _ScrubArea extends StatelessWidget {
  const _ScrubArea({
    required this.child,
    required this.pxPerSec,
    required this.duration,
    this.onScrub,
    this.dragToScrub = true,
  });

  final Widget child;
  final double pxPerSec;
  final double duration;
  final ValueChanged<double>? onScrub;

  /// Off over the lanes: a horizontal-drag recognizer there would fight the
  /// clips' own pan recognizers for the arena and steal clip drags.
  final bool dragToScrub;

  void _emit(Offset local) => onScrub?.call((local.dx / pxPerSec).clamp(0.0, duration + 4));

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _emit(d.localPosition),
      onHorizontalDragStart: dragToScrub ? (d) => _emit(d.localPosition) : null,
      onHorizontalDragUpdate: dragToScrub ? (d) => _emit(d.localPosition) : null,
      child: child,
    );
  }
}

class _TimelineToolbar extends StatelessWidget {
  const _TimelineToolbar({
    required this.canDelete,
    required this.snap,
    required this.zoom,
    this.onSplit,
    this.onDelete,
    this.onAddMarker,
    this.onAddTrack,
    this.onSnapChanged,
    this.onZoomChanged,
    this.onFit,
  });

  final bool canDelete;
  final bool snap;
  final double zoom;
  final VoidCallback? onSplit;
  final void Function({required bool ripple})? onDelete;
  final VoidCallback? onAddMarker;
  final ValueChanged<String>? onAddTrack;
  final ValueChanged<bool>? onSnapChanged;
  final ValueChanged<double>? onZoomChanged;
  final VoidCallback? onFit;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(border: CcBorders.bottom),
      child: Row(
        children: [
          CcTappable(onTap: onSplit, child: const CcIcon(LucideIcons.scissors, size: 14)),
          const SizedBox(width: 14),
          CcTappable(
            onTap: canDelete ? () => onDelete?.call(ripple: false) : null,
            child: CcIcon(
              LucideIcons.trash2,
              size: 14,
              color: canDelete ? CcColors.textPrimary : CcColors.textTertiary,
            ),
          ),
          const SizedBox(width: 14),
          CcTappable(onTap: onAddMarker, child: const CcIcon(LucideIcons.flag, size: 14)),
          const SizedBox(width: 14),
          CcTappable(
            onTap: onSnapChanged == null ? null : () => onSnapChanged!(!snap),
            child: CcIcon(
              LucideIcons.magnet,
              size: 14,
              color: snap ? CcColors.accent : CcColors.textTertiary,
            ),
          ),
          const SizedBox(width: 14),
          const CcDivider(height: 16),
          const SizedBox(width: 14),
          CcTappable(
            onTap: onAddTrack == null ? null : () => onAddTrack!('video'),
            child: Text(
              '+ Track',
              style: CcType.style(size: 11, color: CcColors.textSecondary),
            ),
          ),
          const Spacer(),
          CcTappable(
            onTap: onZoomChanged == null
                ? null
                : () => onZoomChanged!((zoom - 0.1).clamp(0, 1)),
            child: const CcIcon(LucideIcons.zoomOut, size: 14),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 80,
            child: CcSlider(
              value: zoom.clamp(0, 1),
              trackHeight: 3,
              handleSize: 9,
              onChanged: onZoomChanged,
            ),
          ),
          const SizedBox(width: 10),
          CcTappable(
            onTap: onZoomChanged == null
                ? null
                : () => onZoomChanged!((zoom + 0.1).clamp(0, 1)),
            child: const CcIcon(LucideIcons.zoomIn, size: 14),
          ),
          const SizedBox(width: 10),
          CcTappable(
            onTap: onFit,
            child: const CcIcon(LucideIcons.scan, size: 14, color: CcColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// Second ruler. The tick interval steps up with zoom so labels never crowd.
class TimelineRuler extends StatelessWidget {
  const TimelineRuler({
    super.key,
    required this.width,
    required this.durationSeconds,
    this.pxPerSec = kPixelsPerSecond,
    this.markers = const [],
    this.playheadSeconds = 0,
  });

  static const _ladder = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600];

  final double width;
  final double durationSeconds;
  final double pxPerSec;
  final List<TimelineMarker> markers;
  final double playheadSeconds;

  /// Smallest interval from the ladder that leaves ≥ 64 px between labels.
  double get step =>
      _ladder.firstWhere((s) => s * pxPerSec >= 64, orElse: () => _ladder.last).toDouble();

  static String label(double seconds) {
    final total = seconds.round();
    final m = total ~/ 60;
    final s = total % 60;
    if (seconds < 1 && seconds > 0) return '${seconds.toStringAsFixed(1)}s';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final ticks = (width / pxPerSec / step).ceil();
    return Container(
      height: TimelinePanel.rulerHeight,
      width: width,
      decoration: const BoxDecoration(color: CcColors.panel, border: CcBorders.bottom),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i <= ticks; i++) ...[
            Positioned(
              left: i * step * pxPerSec,
              bottom: 0,
              child: Container(width: 1, height: 8, color: CcColors.borderStrong),
            ),
            Positioned(
              left: i * step * pxPerSec + 4,
              top: 4,
              child: Text(label(i * step), style: CcType.nano),
            ),
          ],
          for (final marker in markers)
            Positioned(
              left: marker.seconds * pxPerSec - 3,
              top: 3,
              child: const CcIcon(LucideIcons.flag, size: 10, color: CcColors.warning),
            ),
          Positioned(
            left: playheadSeconds * pxPerSec - 6,
            bottom: 2,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: CcColors.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Lane extends StatelessWidget {
  const _Lane({
    required this.track,
    required this.index,
    required this.pxPerSec,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.selectedClipId,
    this.onSelect,
  });

  final TimelineTrack track;
  final int index;
  final double pxPerSec;
  final String? selectedClipId;
  final ValueChanged<String?>? onSelect;
  final void Function(TimelineClip clip, int trackIndex, _DragMode mode) onDragStart;
  final ValueChanged<DragUpdateDetails> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: track.height,
      decoration: BoxDecoration(
        color: track.locked ? CcColors.elevated : CcColors.bg,
        border: const Border(bottom: BorderSide(color: CcColors.border)),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final clip in track.clips)
            Positioned(
              left: clip.start * pxPerSec,
              width: (clip.duration * pxPerSec).clamp(2.0, double.infinity),
              top: 0,
              child: _ClipHandles(
                clip: clip,
                trackIndex: index,
                height: track.height,
                locked: track.locked,
                selected: clip.selected || clip.id == selectedClipId,
                onSelect: onSelect,
                onDragStart: onDragStart,
                onDragUpdate: onDragUpdate,
                onDragEnd: onDragEnd,
              ),
            ),
          for (final clip in track.clips)
            if (clip.transitionAfterStart)
              Positioned(
                left: clip.start * pxPerSec,
                top: 0,
                child: TransitionBadge(height: track.height),
              ),
        ],
      ),
    );
  }
}

/// A clip plus its three gesture zones: head trim, body move, tail trim.
class _ClipHandles extends StatelessWidget {
  const _ClipHandles({
    required this.clip,
    required this.trackIndex,
    required this.height,
    required this.selected,
    required this.locked,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.onSelect,
  });

  final TimelineClip clip;
  final int trackIndex;
  final double height;
  final bool selected;
  final bool locked;
  final ValueChanged<String?>? onSelect;
  final void Function(TimelineClip clip, int trackIndex, _DragMode mode) onDragStart;
  final ValueChanged<DragUpdateDetails> onDragUpdate;
  final VoidCallback onDragEnd;

  Widget _zone({required _DragMode mode, required MouseCursor cursor, Widget? child}) {
    return MouseRegion(
      cursor: locked ? SystemMouseCursors.basic : cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => onSelect?.call(clip.id),
        onPanStart: locked ? null : (_) => onDragStart(clip, trackIndex, mode),
        onPanUpdate: locked ? null : onDragUpdate,
        onPanEnd: locked ? null : (_) => onDragEnd(),
        onPanCancel: locked ? null : onDragEnd,
        child: child ?? const SizedBox.expand(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          _zone(
            mode: _DragMode.move,
            cursor: SystemMouseCursors.grab,
            child: TimelineClipTile(clip: clip, height: height, selected: selected),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: _kTrimHandle,
            child: _zone(mode: _DragMode.trimStart, cursor: SystemMouseCursors.resizeLeftRight),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: _kTrimHandle,
            child: _zone(mode: _DragMode.trimEnd, cursor: SystemMouseCursors.resizeLeftRight),
          ),
        ],
      ),
    );
  }
}

class _SnapLine extends StatelessWidget {
  const _SnapLine();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(width: 1, child: ColoredBox(color: CcColors.warning));
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
