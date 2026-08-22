import 'dart:io';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../app/router/app_router.gr.dart';
import '../../../../app/session.dart';
import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/cc_dialog.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../models/rational.dart';
import '../../../../engine/engine.dart' show PlatformHelper;
import '../../../../state/editor_controller.dart';
import '../../../../state/project_tools.dart';
import '../models/editor_models.dart';
import '../widgets/editor_toolbar.dart';
import '../widgets/inspector/inspector_panel.dart';
import '../widgets/media_pool.dart';
import '../widgets/missing_media_dialog.dart';
import '../widgets/mixer_panel.dart';
import '../widgets/monitor_panel.dart';
import '../widgets/timeline/timeline_panel.dart';

/// The editor: toolbar on top, media pool / monitor / inspector in the middle,
/// timeline at the bottom. The screen translates gestures and keys into
/// controller calls and owns only view state (zoom, snap, fullscreen).
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
        'mp4', 'mov', 'mkv', 'webm', 'm4v',
        'wav', 'mp3', 'aac', 'm4a', 'flac', 'ogg',
        'png', 'jpg', 'jpeg', 'webp', 'gif',
      ],
    ),
  ];

  final _focus = FocusNode(debugLabel: 'editor');
  int _tool = 0;
  bool _snap = true;
  bool _dropActive = false;
  bool _fullscreen = false;

  /// The mixer replaces the inspector column when open (AUD-10).
  bool _mixer = false;
  double _pxPerSec = kPixelsPerSecond;
  double _lanesWidth = 800;

  EditorController? get _controller =>
      AppSession.instance.hasProject ? AppSession.instance.editor : null;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // --- Zoom (TIM-14) --------------------------------------------------------

  /// Slider position 0..1 mapped exponentially so the low end still gives
  /// frame-level steps.
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

  /// Pointer-anchored zoom: the time under the cursor stays put.
  void _zoomAt(double steps, double anchorSeconds) => _zoomBy(steps * 0.25);

  void _fit(EditorController c) {
    final seconds = c.duration.seconds;
    if (seconds <= 0) return;
    setState(() {
      _pxPerSec = (_lanesWidth / seconds).clamp(kMinPxPerSec, kMaxPxPerSec);
    });
  }

  // --- Import / export ------------------------------------------------------

  Future<void> _browseForMedia(EditorController c) async {
    final files = await openFiles(acceptedTypeGroups: _mediaTypes);
    if (files.isEmpty) return;
    await c.importPaths(files.map((f) => f.path).toList());
  }

  Future<void> _saveCopy(EditorController c) async {
    final location = await getSaveLocation(
      suggestedName: '${c.doc.name}.crazycut',
      acceptedTypeGroups: const [XTypeGroup(label: 'CrazyCut project', extensions: ['crazycut'])],
    );
    if (location == null) return;
    await c.saveCopy(location.path);
  }

  Future<void> _relinkOffline(EditorController c) async {
    if (c.offlineAssets.isEmpty) return;
    // IMP-15/16: the panel matches by content hash first, then by name, and
    // never repoints a clip at a file the user did not confirm.
    await showMissingMediaDialog(context, c);
  }

  /// PRJ-14: copy referenced media beside the project, with the size shown up
  /// front so a 40 GB copy is never a surprise.
  Future<void> _collectMedia(EditorController c) async {
    final projectPath = c.path;
    final plan = ProjectTools.planCollect(c.doc, projectPath);
    if (!mounted) return;
    if (plan.isEmpty) {
      await confirmAction(
        context,
        title: 'Collect media',
        message: plan.missing.isEmpty
            ? 'Every asset already lives in this project folder.'
            : '${plan.missing.length} asset(s) are offline and cannot be '
                'collected. Relink them first.',
        confirmLabel: 'OK',
      );
      return;
    }
    final go = await confirmAction(
      context,
      title: 'Collect media to project folder',
      message: 'Copy ${plan.assets.length} file(s) — ${plan.sizeLabel} — into '
          '${ProjectTools.mediaFolder(projectPath).path} and repoint the '
          'project at the copies?',
      confirmLabel: 'Collect',
    );
    if (!go) return;
    final result = await ProjectTools.collect(c.doc, projectPath);
    c.markDirty();
    await c.saveNow();
    if (!mounted) return;
    await confirmAction(
      context,
      title: 'Collect media',
      message: result.error != null
          ? 'Copied ${result.copied} file(s), then stopped: ${result.error}'
          : 'Copied ${result.copied} file(s). '
              '${result.skipped} were already in the project folder.',
      confirmLabel: 'OK',
    );
  }

  /// A support bundle next to the project (M4 diagnostics).
  Future<void> _writeDiagnostics(EditorController c) async {
    final file = await ProjectTools.writeDiagnostics(
      doc: c.doc,
      projectPath: c.path,
      engineLib: PlatformHelper.engineLibCandidates().firstWhere(
        (candidate) => File(candidate).existsSync(),
        orElse: () => 'not found',
      ),
    );
    if (!mounted) return;
    await confirmAction(
      context,
      title: 'Diagnostics saved',
      message: file.path,
      confirmLabel: 'OK',
    );
  }

  // --- Keyboard (04-ui-ux §7) ----------------------------------------------

  KeyEventResult _onKey(EditorController c, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final meta = keys.isMetaPressed || keys.isControlPressed;
    final shift = keys.isShiftPressed;
    final alt = keys.isAltPressed;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        c.togglePlay();
      case LogicalKeyboardKey.keyS when meta && shift:
        _saveCopy(c);
      case LogicalKeyboardKey.keyS when meta:
        c.saveNow();
      case LogicalKeyboardKey.keyS:
        c.splitAtPlayhead();
      case LogicalKeyboardKey.keyM:
        c.addMarker();
      case LogicalKeyboardKey.keyI when meta:
        _browseForMedia(c);
      case LogicalKeyboardKey.keyI:
        c.setInPoint();
      case LogicalKeyboardKey.keyO:
        c.setOutPoint();
      case LogicalKeyboardKey.keyX when alt:
        c.clearInOut();
      case LogicalKeyboardKey.keyX when meta:
        c.cutSelection();
      case LogicalKeyboardKey.keyC when meta:
        c.copySelection();
      case LogicalKeyboardKey.keyV when meta:
        c.paste();
      case LogicalKeyboardKey.keyD when meta:
        c.duplicateSelection();
      case LogicalKeyboardKey.keyA when meta:
        c.selectAll();
      case LogicalKeyboardKey.keyE when meta:
        context.router.push(ExportRoute(empty: c.doc.clips.isEmpty));
      case LogicalKeyboardKey.keyF:
        setState(() => _fullscreen = !_fullscreen);
      case LogicalKeyboardKey.keyJ:
        c.shuttle(forward: false);
      case LogicalKeyboardKey.keyK:
        c.stopPlayback();
      case LogicalKeyboardKey.keyL:
        c.shuttle(forward: true, slow: keys.logicalKeysPressed.contains(LogicalKeyboardKey.keyK));
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
      case LogicalKeyboardKey.arrowUp:
        c.jumpToMarker(forward: false);
      case LogicalKeyboardKey.arrowDown:
        c.jumpToMarker(forward: true);
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
        if (_fullscreen) {
          setState(() => _fullscreen = false);
        } else {
          c.selectClip(null);
        }
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
    final empty = c.doc.clips.isEmpty;

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (node, event) => _onKey(c, event),
      child: DropTarget(
        onDragEntered: (_) => setState(() => _dropActive = true),
        onDragExited: (_) => setState(() => _dropActive = false),
        onDragDone: (detail) {
          setState(() => _dropActive = false);
          c.importPaths(detail.files.map((f) => f.path).toList());
        },
        child: ColoredBox(
          color: CcColors.bg,
          child: _fullscreen
              ? MonitorPanel(
                  controller: c,
                  fullscreen: true,
                  onExitFullscreen: () => setState(() => _fullscreen = false),
                )
              : Column(
                  children: [
                    EditorToolbar(
                      selectedTool: _tool,
                      onToolChanged: (i) => setState(() => _tool = i),
                      onBack: () async {
                        await AppSession.instance.close();
                        if (context.mounted) context.router.maybePop();
                      },
                      onExport: () => context.router.push(ExportRoute(empty: empty)),
                      onUndo: c.undo,
                      onRedo: c.redo,
                      canUndo: c.canUndo,
                      canRedo: c.canRedo,
                      snap: _snap,
                      onSnapChanged: (v) => setState(() => _snap = v),
                      saveState: c.saveState,
                      projectName: c.doc.name,
                      onRename: () => _renameProject(c),
                      offlineCount: c.offlineAssets.length,
                      onRelink: () => _relinkOffline(c),
                      mixerOpen: _mixer,
                      onToggleMixer: () => setState(() => _mixer = !_mixer),
                      onCollectMedia: () => _collectMedia(c),
                      onDiagnostics: () => _writeDiagnostics(c),
                    ),
                    Expanded(
                      flex: 560,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          MediaPool(
                            controller: c,
                            dropActive: _dropActive,
                            onImport: () => _browseForMedia(c),
                          ),
                          Expanded(
                            child: MonitorPanel(
                              controller: c,
                              onFullscreen: () => setState(() => _fullscreen = true),
                            ),
                          ),
                          if (_mixer)
                            SizedBox(
                              width: 300,
                              child: MixerPanel(
                                controller: c,
                                onClose: () => setState(() => _mixer = false),
                              ),
                            )
                          else
                            InspectorPanel(controller: c),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 388,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _lanesWidth = constraints.maxWidth - 160;
                          return TimelinePanel(
                            controller: c,
                            pxPerSec: _pxPerSec,
                            snap: _snap,
                            onSnapChanged: (v) => setState(() => _snap = v),
                            onZoomChanged: _setZoom,
                            onZoomAt: _zoomAt,
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

  Future<void> _renameProject(EditorController c) async {
    final name = await promptForText(
      context,
      title: 'Rename project',
      initialValue: c.doc.name,
    );
    if (name != null && name.isNotEmpty) await c.rename(name);
  }
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
