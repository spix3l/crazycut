import 'dart:typed_data';
import 'package:flutter/material.dart' show showModalBottomSheet, TextField, InputDecoration;
import 'package:flutter/widgets.dart' hide Clip;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../core/widgets/rgba_frame.dart';
import '../../../../state/editor_controller.dart';

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
    return ColoredBox(
      color: CcColors.bg,
      child: Column(
        children: [
          if (!widget.fullscreen)
            _MonitorToolbar(onFullscreen: widget.onFullscreen)
          else
            _FullscreenBar(onExit: widget.onExitFullscreen),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.fullscreen ? 0 : 24,
                vertical: widget.fullscreen ? 0 : 20,
              ),
              child: Center(
                child: AspectRatio(
                  aspectRatio: c.doc.settings.width / c.doc.settings.height,
                  child: GestureDetector(
                    onDoubleTap: () => _editTextUnderPlayhead(context),
                    child: switch ((empty, c.previewFrame)) {
                      (true, _) =>
                        const _Placeholder(message: 'Nothing on the timeline yet'),
                      (false, final bytes?) when c.previewFrameSize != null =>
                        _FramePreview(
                          bytes: bytes,
                          width: c.previewFrameSize!.$1,
                          height: c.previewFrameSize!.$2,
                        ),
                      _ => const _Placeholder(message: 'No frame under the playhead'),
                    },
                  ),
                ),
              ),
            ),
          ),
          _TransportBar(controller: c),
        ],
      ),
    );
  }
}

class _MonitorToolbar extends StatelessWidget {
  const _MonitorToolbar({this.onFullscreen});

  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const CcIcon(LucideIcons.squareDashed, size: 15, color: CcColors.textTertiary),
            const SizedBox(width: 14),
            const CcIcon(LucideIcons.grid3x3, size: 15, color: CcColors.textTertiary),
            const Spacer(),
            CcTooltip(
              message: 'Fullscreen preview (F)',
              child: CcTappable(
                onTap: onFullscreen,
                child: const CcIcon(LucideIcons.expand, size: 15, color: CcColors.textTertiary),
              ),
            ),
            const SizedBox(width: 12),
            const CcDropdown(value: 'Fit', height: 23, fontSize: 11),
            const SizedBox(width: 8),
            const CcDropdown(value: 'Full', height: 23, fontSize: 11),
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
      decoration: const BoxDecoration(color: Color(0xFF000000), border: CcBorders.all),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CcIcon(LucideIcons.film, size: 28, color: CcColors.textTertiary),
          const SizedBox(height: 10),
          Text(message, style: CcType.style(size: 13, color: CcColors.textTertiary)),
        ],
      ),
    );
  }
}

class _FramePreview extends StatelessWidget {
  const _FramePreview({required this.bytes, required this.width, required this.height});

  final Uint8List bytes;
  final int width;
  final int height;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF000000),
      child: RgbaFrame(bytes: bytes, width: width, height: height),
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
                  Text(c.timecode, style: CcType.bodyStrong),
                  const SizedBox(width: 4),
                  Text('/', style: CcType.style(size: 13, color: CcColors.textTertiary)),
                  const SizedBox(width: 4),
                  Text(
                    c.durationTimecode,
                    style: CcType.style(size: 13, color: CcColors.textTertiary),
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
                      color: c.looping ? CcColors.accent : CcColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _MasterMeter(active: c.playing && !empty),
            ),
          ],
        ),
      ),
    );
  }
}

/// Eight-bar output meter; flat when nothing is playing. Real levels arrive
/// with the mixer in M3.
class _MasterMeter extends StatelessWidget {
  const _MasterMeter({required this.active});

  static const List<double> _levels = [10, 18, 26, 20, 14, 22, 30, 16];

  final bool active;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < _levels.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Container(
              width: 4,
              height: active ? _levels[i] : 3.0,
              decoration: BoxDecoration(
                color: active ? CcColors.success : CcColors.borderStrong,
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
