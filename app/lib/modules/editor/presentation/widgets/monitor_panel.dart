import 'dart:math' as math;
import 'package:flutter/material.dart'
    show showModalBottomSheet, TextField, InputDecoration;
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/core/widgets/rgba_frame.dart';
import 'package:crazycut_app/core/math/rational.dart';
import 'package:crazycut_app/modules/editor/application/editor_controller.dart';
import 'package:crazycut_app/modules/editor/infrastructure/preview_renderer.dart';
import 'area_track_overlay.dart';
import 'canvas_gizmo.dart';

/// Centre column: overlay toggles, the program monitor and the transport bar.
class MonitorPanel extends StatefulWidget {
  const MonitorPanel({
    super.key,
    required this.controller,
    this.fullscreen = false,
    this.onFullscreen,
    this.onExitFullscreen,
  });

  final EditorController controller;
  final bool fullscreen;
  final VoidCallback? onFullscreen;
  final VoidCallback? onExitFullscreen;

  @override
  State<MonitorPanel> createState() => _MonitorPanelState();
}

class _MonitorPanelState extends State<MonitorPanel> {
  EditorController get controller => widget.controller;

  /// TXT-6: double-click a text clip's frame opens an inline editor bound to
  /// the clip under the playhead.
  void _editTextUnderPlayhead(BuildContext context) {
    final clip = controller.textClipUnderPlayhead();
    if (clip == null) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _TextEditorSheet(controller: controller, clipId: clip.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final empty = c.doc.clips.isEmpty;
    final aspectRatio = c.doc.settings.width / c.doc.settings.height;

    final frame = GestureDetector(
      onDoubleTap: () => _editTextUnderPlayhead(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _PreviewSizeReporter(
            controller: c,
            child:
                empty
                    ? const _Placeholder(message: 'Nothing on the timeline yet')
                    : _FramePreview(controller: c),
          ),
          // TXT-6: move/resize/rotate handles over the frame.
          // Layered above the preview but only claims pointers
          // that land on it, so the double-tap above survives.
          // The two canvas tools are mutually exclusive: arming the region
          // tool takes the transform handles off the frame, so a drag is never
          // ambiguous about which one it meant.
          if (!empty && !c.trackToolActive) CanvasGizmo(controller: c),
          // TRK-1/2. Mounted whenever there is a clip, not only while the tool
          // is armed: it also draws the solved region following the subject,
          // which is what shows a track is working before any image is pinned
          // to it. It renders nothing when there is neither.
          if (!empty) AreaTrackOverlay(controller: c),
          if (c.showCanvasGrid) const IgnorePointer(child: _GridOverlay()),
          if (c.showSafeMargins)
            const IgnorePointer(child: _SafeMarginsOverlay()),
        ],
      ),
    );

    return ColoredBox(
      color: CcColors.bg,
      child: Column(
        children: [
          if (!widget.fullscreen)
            _MonitorToolbar(controller: c, onFullscreen: widget.onFullscreen)
          else
            _FullscreenBar(onExit: widget.onExitFullscreen),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.fullscreen ? 0 : 24,
                vertical: widget.fullscreen ? 0 : 20,
              ),
              child:
                  c.previewZoom == PreviewZoom.fit
                      ? Center(
                        child: AspectRatio(
                          aspectRatio: aspectRatio,
                          child: frame,
                        ),
                      )
                      : _ZoomedStage(
                        width: c.doc.settings.width * c.previewZoom.scale,
                        height: c.doc.settings.height * c.previewZoom.scale,
                        child: frame,
                      ),
            ),
          ),
          _TransportBar(controller: c),
        ],
      ),
    );
  }
}

/// Non-"Fit" zoom levels: the canvas is shown at a fixed fraction of
/// sequence resolution and scrolls if it doesn't fit the available space,
/// rather than being squeezed back down (that would make the zoom control a
/// no-op).
class _ZoomedStage extends StatelessWidget {
  const _ZoomedStage({
    required this.width,
    required this.height,
    required this.child,
  });

  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );
  }
}

/// UIX 3.2 rule-of-thirds style reference grid over the canvas.
class _GridOverlay extends StatelessWidget {
  const _GridOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _GridPainter());
  }
}

class _GridPainter extends CustomPainter {
  static const _divisions = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = const Color(0x66FFFFFF)
          ..strokeWidth = 1;
    for (var i = 1; i < _divisions; i++) {
      final x = size.width * i / _divisions;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      final y = size.height * i / _divisions;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// UIX 3.2 action-safe (90%) and title-safe (80%) margin guides.
class _SafeMarginsOverlay extends StatelessWidget {
  const _SafeMarginsOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _SafeMarginsPainter());
  }
}

class _SafeMarginsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = const Color(0x99FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
    void inset(double fraction) {
      final dx = size.width * (1 - fraction) / 2;
      final dy = size.height * (1 - fraction) / 2;
      canvas.drawRect(
        Rect.fromLTWH(dx, dy, size.width - dx * 2, size.height - dy * 2),
        paint,
      );
    }

    inset(0.9); // action-safe
    inset(0.8); // title-safe
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MonitorToolbar extends StatelessWidget {
  const _MonitorToolbar({required this.controller, this.onFullscreen});

  final EditorController controller;
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            CcTooltip(
              message: 'Safe margins',
              child: CcTappable(
                onTap: () => c.setShowSafeMargins(!c.showSafeMargins),
                child: CcIcon(
                  LucideIcons.squareDashed,
                  size: 15,
                  color:
                      c.showSafeMargins
                          ? CcColors.textPrimary
                          : CcColors.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: 14),
            CcTooltip(
              message: 'Grid',
              child: CcTappable(
                onTap: () => c.setShowCanvasGrid(!c.showCanvasGrid),
                child: CcIcon(
                  LucideIcons.grid3x3,
                  size: 15,
                  color:
                      c.showCanvasGrid
                          ? CcColors.textPrimary
                          : CcColors.textTertiary,
                ),
              ),
            ),
            const Spacer(),
            CcTooltip(
              message: 'Fullscreen preview (F)',
              child: CcTappable(
                onTap: onFullscreen,
                child: const CcIcon(
                  LucideIcons.expand,
                  size: 15,
                  color: CcColors.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Builder(
              builder:
                  (anchorContext) => CcDropdown(
                    value: c.previewZoom.label,
                    height: 23,
                    fontSize: 11,
                    onTap:
                        () => showCcMenu(anchorContext, [
                          for (final zoom in PreviewZoom.values)
                            CcMenuItem(
                              zoom.label,
                              checked: zoom == c.previewZoom,
                              onTap: () => c.setPreviewZoom(zoom),
                            ),
                        ]),
                  ),
            ),
            const SizedBox(width: 8),
            Builder(
              builder:
                  (anchorContext) => CcDropdown(
                    value: c.previewQuality.label,
                    height: 23,
                    fontSize: 11,
                    onTap:
                        () => showCcMenu(anchorContext, [
                          for (final quality in PreviewQuality.values)
                            CcMenuItem(
                              quality.label,
                              checked: quality == c.previewQuality,
                              onTap: () => c.setPreviewQuality(quality),
                            ),
                        ]),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenBar extends StatelessWidget {
  const _FullscreenBar({this.onExit});

  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Spacer(),
            CcTappable(
              onTap: onExit,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CcIcon(LucideIcons.shrink, size: 14),
                  const SizedBox(width: 6),
                  Text('Exit fullscreen (Esc)', style: CcType.tiny),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF000000),
        border: CcBorders.all,
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CcIcon(
            LucideIcons.film,
            size: 28,
            color: CcColors.textTertiary,
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: CcType.style(size: 13, color: CcColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// Tells the controller how many device pixels the monitor actually paints
/// into, so frames are rendered at display resolution rather than a fixed
/// low-res size and then upscaled.
class _PreviewSizeReporter extends StatelessWidget {
  const _PreviewSizeReporter({required this.controller, required this.child});

  final EditorController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final pixels = (constraints.maxWidth * dpr).round();
        if (pixels > 0) {
          // Deferred: setPreviewWidth can kick off a render and notify.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => controller.setPreviewWidth(pixels),
          );
        }
        return child;
      },
    );
  }
}

/// Repaints straight off the controller's preview channel.
///
/// Frames land 30-60 times a second while the transport runs; listening to the
/// notifier instead of the controller keeps that rate inside this subtree
/// rather than rebuilding the editor around it.
class _FramePreview extends StatelessWidget {
  const _FramePreview({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    // Sampling a moving image through a mipmap chain costs a filter pass per
    // frame for detail nobody can see at transport speed; the parked frame
    // gets the sharper sampler back.
    final quality =
        controller.playing ? FilterQuality.low : FilterQuality.medium;
    return ColoredBox(
      color: const Color(0xFF000000),
      child: ValueListenableBuilder<PreviewFrame?>(
        valueListenable: controller.previewImage,
        builder: (context, frame, _) {
          if (frame == null) {
            return const _Placeholder(message: 'No frame under the playhead');
          }
          return RgbaFrame(
            bytes: frame.rgba,
            width: frame.width,
            height: frame.height,
            filterQuality: quality,
          );
        },
      ),
    );
  }
}

class _TransportBar extends StatelessWidget {
  const _TransportBar({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final empty = c.doc.clips.isEmpty;
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Follows the playhead at transport rate; the rest of the
                  // transport bar only changes when the transport state does.
                  ValueListenableBuilder<Rt>(
                    valueListenable: c.playheadNotifier,
                    builder:
                        (context, _, _) =>
                            Text(c.timecode, style: CcType.timecode),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '/',
                    style: CcType.style(size: 13, color: CcColors.textTertiary),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    c.durationTimecode,
                    style: CcType.value.copyWith(color: CcColors.textTertiary),
                  ),
                  if (c.shuttleRate != 1 && c.playing) ...[
                    const SizedBox(width: 10),
                    Text(
                      '${c.shuttleRate > 0 ? '' : '−'}${c.shuttleRate.abs()}×',
                      style: CcType.style(size: 11, color: CcColors.accent),
                    ),
                  ],
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CcTooltip(
                  message: 'Previous edit (PageUp)',
                  child: CcTappable(
                    onTap: () => c.jumpToEdge(forward: false),
                    child: const CcIcon(LucideIcons.skipBack, size: 16),
                  ),
                ),
                const SizedBox(width: 18),
                CcTappable(
                  onTap: c.togglePlay,
                  child: Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: empty ? CcColors.elevated2 : CcColors.accent,
                      shape: BoxShape.circle,
                    ),
                    child: CcIcon(
                      c.playing ? LucideIcons.pause : LucideIcons.play,
                      size: 15,
                      color: CcColors.onAccent,
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                CcTooltip(
                  message: 'Next edit (PageDown)',
                  child: CcTappable(
                    onTap: () => c.jumpToEdge(forward: true),
                    child: const CcIcon(LucideIcons.skipForward, size: 16),
                  ),
                ),
                const SizedBox(width: 18),
                CcTooltip(
                  message: 'Loop the in/out range',
                  child: CcTappable(
                    onTap: c.toggleLoop,
                    child: CcIcon(
                      LucideIcons.repeat,
                      size: 15,
                      color:
                          c.looping ? CcColors.accent : CcColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              // Meter ballistics come off their own channel, so the needle
              // stays smooth without the transport bar rebuilding per tick.
              child: ValueListenableBuilder<(double, double)>(
                valueListenable: c.audioLevelsNotifier,
                builder:
                    (context, levels, _) => _MasterMeter(
                      levels: c.playing && !empty ? levels : (0, 0),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Master output meter, always visible in the transport bar (AUD-10). Levels
/// are the peaks the audio device last played, so a silent project shows a
/// flat meter rather than a decorative animation.
class _MasterMeter extends StatelessWidget {
  const _MasterMeter({required this.levels});

  final (double, double) levels;

  /// dB scale: a linear bar wastes its length on levels nobody mixes at.
  static double _norm(double amplitude) {
    if (amplitude <= 0) return 0;
    final db = 20 * (math.log(amplitude) / math.ln10);
    return ((db + 60) / 60).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final level in [levels.$1, levels.$2]) ...[
            const SizedBox(width: 3),
            Container(
              width: 6,
              height: 3 + 27 * _norm(level),
              decoration: BoxDecoration(
                color:
                    level > 0.95
                        ? CcColors.error
                        : level > 0.7
                        ? CcColors.warning
                        : CcColors.success,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Minimal inline text editor (TXT-6): content plus quick style controls.
class _TextEditorSheet extends StatefulWidget {
  const _TextEditorSheet({required this.controller, required this.clipId});

  final EditorController controller;
  final String clipId;

  @override
  State<_TextEditorSheet> createState() => _TextEditorSheetState();
}

class _TextEditorSheetState extends State<_TextEditorSheet> {
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(
      text: widget.controller.clipById(widget.clipId)?.text?.content ?? '',
    );
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clip = widget.controller.clipById(widget.clipId);
    if (clip == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _field,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Type…'),
            onChanged: (v) => widget.controller.setTextContent(clip.id, v),
          ),
        ],
      ),
    );
  }
}
