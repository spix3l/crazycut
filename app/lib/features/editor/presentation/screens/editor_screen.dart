import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/widgets.dart';

import '../../../../app/router/app_router.gr.dart';
import '../../../../app/session.dart';
import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../models/rational.dart';
import '../../../../state/editor_controller.dart';
import '../models/editor_models.dart';
import '../widgets/editor_toolbar.dart';
import '../widgets/inspector/inspector_panel.dart';
import '../widgets/media_pool.dart';
import '../widgets/monitor_panel.dart';
import '../widgets/timeline/timeline_panel.dart';

/// The editor: toolbar on top, media pool / monitor / inspector in the middle,
/// timeline at the bottom. Everything is bound to the open project's
/// [EditorController]; the screen only translates gestures and keys into
/// controller calls.
@RoutePage()
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  static const _mediaTypes = [
    XTypeGroup(
      label: 'Media',
      extensions: [
        'mp4',
        'mov',
        'm4v',
        'mkv',
        'wav',
        'mp3',
        'aac',
        'm4a',
        'png',
        'jpg',
        'jpeg',
      ],
    ),
  ];

  final _focus = FocusNode(debugLabel: 'editor');
  int _tool = 0;
  bool _snap = true;
  bool _dropActive = false;
  double _pxPerSec = kPixelsPerSecond;
  double _lanesWidth = 800;

  EditorController? get _controller =>
      AppSession.instance.hasProject ? AppSession.instance.editor : null;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // --- Zoom -----------------------------------------------------------------

  /// Slider position 0..1 mapped exponentially, so the low end still gives
  /// useful frame-level steps.
  void _setZoom(double t) {
    final clamped = t.clamp(0.0, 1.0);
    setState(() {
      _pxPerSec = kMinPxPerSec * math.pow(kMaxPxPerSec / kMinPxPerSec, clamped);
    });
  }

  double get _zoomT {
    final ratio = _pxPerSec / kMinPxPerSec;
    final span = kMaxPxPerSec / kMinPxPerSec;
    return (math.log(ratio) / math.log(span)).clamp(0.0, 1.0);
  }

  void _zoomBy(double delta) => _setZoom(_zoomT + delta);

  void _fit(EditorController c) {
    final seconds = c.duration.seconds;
    if (seconds <= 0) return;
    setState(() {
      _pxPerSec = (_lanesWidth / seconds).clamp(kMinPxPerSec, kMaxPxPerSec);
    });
  }

  // --- Import ---------------------------------------------------------------

  Future<void> _browseForMedia(EditorController c) async {
    final files = await openFiles(acceptedTypeGroups: _mediaTypes);
    if (files.isEmpty) return;
    await c.importFiles(files.map((f) => f.path).toList());
  }

  // --- Keyboard (04-ui-ux §7) ----------------------------------------------

  KeyEventResult _onKey(EditorController c, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final meta = keys.isMetaPressed || keys.isControlPressed;
    final shift = keys.isShiftPressed;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        c.togglePlay();
      case LogicalKeyboardKey.keyS when meta:
        c.saveNow();
      case LogicalKeyboardKey.keyS:
        c.splitAtPlayhead();
      case LogicalKeyboardKey.keyM:
        c.addMarker();
      case LogicalKeyboardKey.keyJ:
        c.shuttle(forward: false);
      case LogicalKeyboardKey.keyK:
        c.stopPlayback();
      case LogicalKeyboardKey.keyL:
        c.shuttle(forward: true);
      case LogicalKeyboardKey.keyZ when meta && shift:
        c.redo();
      case LogicalKeyboardKey.keyZ when meta:
        c.undo();
      case LogicalKeyboardKey.delete:
      case LogicalKeyboardKey.backspace:
        c.deleteSelected(ripple: shift);
      case LogicalKeyboardKey.arrowLeft:
        shift ? c.seekTo(c.playhead.minus(Rt(1, 1))) : c.stepFrames(-1);
      case LogicalKeyboardKey.arrowRight:
        shift ? c.seekTo(c.playhead.plus(Rt(1, 1))) : c.stepFrames(1);
      case LogicalKeyboardKey.home:
        c.goToStart();
      case LogicalKeyboardKey.end:
        c.goToEnd();
      case LogicalKeyboardKey.pageUp:
        c.jumpToEdge(forward: false);
      case LogicalKeyboardKey.pageDown:
        c.jumpToEdge(forward: true);
      case LogicalKeyboardKey.equal when meta:
        _zoomBy(0.1);
      case LogicalKeyboardKey.minus when meta:
        _zoomBy(-0.1);
      case LogicalKeyboardKey.backslash:
        _fit(c);
      case LogicalKeyboardKey.escape:
        c.selectClip(null);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const _NoProjectOpen();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildEditor(context, controller),
    );
  }

  Widget _buildEditor(BuildContext context, EditorController c) {
    final doc = c.doc;
    final empty = doc.clips.isEmpty;
    final selected = c.selectedClip;
    final tracks = tracksFromProject(
      doc.tracks,
      doc.clips,
      selectedClipId: c.selectedClipId,
      peaksFor: (mediaId) {
        final asset = doc.assetById(mediaId);
        return asset == null ? const [] : c.waveformFor(asset);
      },
    );

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (node, event) => _onKey(c, event),
      child: DropTarget(
        onDragEntered: (_) => setState(() => _dropActive = true),
        onDragExited: (_) => setState(() => _dropActive = false),
        onDragDone: (detail) {
          setState(() => _dropActive = false);
          c.importFiles(detail.files.map((f) => f.path).toList());
        },
        child: ColoredBox(
          color: CcColors.bg,
          child: Column(
            children: [
              EditorToolbar(
                selectedTool: _tool,
                onToolChanged: (i) => setState(() => _tool = i),
                onBack: () async {
                  await c.saveNow();
                  if (context.mounted) context.router.maybePop();
                },
                onExport: () => context.router.push(ExportRoute(empty: empty)),
                onUndo: c.undo,
                onRedo: c.redo,
                canUndo: c.canUndo,
                canRedo: c.canRedo,
                snap: _snap,
                onSnapChanged: (v) => setState(() => _snap = v),
                saveState: c.isDirty ? 'Saving…' : 'Saved',
              ),
              Expanded(
                flex: 560,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MediaPool(
                      assets: _poolAssets(c),
                      dropActive: _dropActive,
                      onImport: () => _browseForMedia(c),
                      onAssetTap: (asset) {
                        if (asset.id != null) c.appendClip(asset.id!);
                      },
                    ),
                    Expanded(
                      child: MonitorPanel(
                        empty: empty,
                        frame: c.previewFrame,
                        playing: c.playing,
                        currentTimecode: c.timecode,
                        totalTimecode: c.durationTimecode,
                        caption: null,
                        onPlayPause: c.togglePlay,
                        onStepBack: () => c.stepFrames(-1),
                        onStepForward: () => c.stepFrames(1),
                      ),
                    ),
                    InspectorPanel(
                      key: ValueKey(selected?.id ?? 'none'),
                      selection: selected == null ? InspectorTarget.none : InspectorTarget.clip,
                      title: selected?.label,
                      sequence: _sequenceSummary(c),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 388,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _lanesWidth = constraints.maxWidth - 160;
                    return TimelinePanel(
                      tracks: tracks,
                      pxPerSec: _pxPerSec,
                      playheadSeconds: c.playhead.seconds,
                      durationSeconds: c.duration.seconds,
                      markers: [
                        for (final m in doc.markers)
                          TimelineMarker(id: m.id, seconds: m.time.seconds, label: m.name),
                      ],
                      snapIndicatorSeconds: c.snapIndicator,
                      showGettingStartedHint: empty,
                      selectedClipId: c.selectedClipId,
                      snap: _snap,
                      onSelect: c.selectClip,
                      onScrub: (seconds) => c.seekTo(Rt.fromSeconds(seconds)),
                      onGestureBegin: c.beginGesture,
                      onGestureEnd: c.endGesture,
                      onMove: (clipId, trackId, start) => c.moveClip(
                        clipId,
                        trackId: trackId,
                        start: Rt.fromSeconds(start),
                        snap: _snap,
                        pxPerSec: _pxPerSec,
                      ),
                      onTrimStart: (clipId, start) => c.trimStart(
                        clipId,
                        Rt.fromSeconds(start),
                        snap: _snap,
                        pxPerSec: _pxPerSec,
                      ),
                      onTrimEnd: (clipId, end) => c.trimEnd(
                        clipId,
                        Rt.fromSeconds(end),
                        snap: _snap,
                        pxPerSec: _pxPerSec,
                      ),
                      onSplit: c.splitAtPlayhead,
                      onDelete: ({required ripple}) => c.deleteSelected(ripple: ripple),
                      onAddMarker: () => c.addMarker(),
                      onAddTrack: c.addTrack,
                      onSnapChanged: (v) => setState(() => _snap = v),
                      onZoomChanged: _setZoom,
                      onFit: () => _fit(c),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<MediaAsset> _poolAssets(EditorController c) => [
    for (final item in c.pool.values) poolItemToAsset(item, item.thumb),
  ];

  SequenceSummary _sequenceSummary(EditorController c) {
    final s = c.doc.settings;
    return SequenceSummary(
      resolution: '${s.width} × ${s.height}',
      frameRate: '${_trimZeros(s.fpsValue)} fps',
      sampleRate: '${(s.audioSampleRate / 1000).round()} kHz',
      duration: c.durationTimecode,
      background: s.background,
    );
  }

  static String _trimZeros(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);
}

/// Reached only by deep link — the editor has nothing to show without a
/// project, so it points back at the browser.
class _NoProjectOpen extends StatelessWidget {
  const _NoProjectOpen();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: CcColors.bg,
      child: Center(
        child: SizedBox(
          width: 320,
          child: CcEmptyState(
            icon: LucideIcons.folderOpen,
            title: 'No project open',
            description: 'Pick a project from the browser to start editing.',
            action: CcButton(
              label: 'Go to projects',
              onPressed: () => context.router.replaceAll([ProjectBrowserRoute()]),
            ),
          ),
        ),
      ),
    );
  }
}
