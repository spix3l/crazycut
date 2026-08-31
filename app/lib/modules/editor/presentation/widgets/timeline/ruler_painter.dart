part of 'timeline_panel.dart';

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
      _ladder
          .firstWhere((s) => s * pxPerSec >= 64, orElse: () => _ladder.last)
          .toDouble();

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
        text: TextSpan(
          text: label(t),
          style: CcType.nano.copyWith(
            fontFeatures: const [ui.FontFeature.tabularFigures()],
          ),
        ),
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
    this.onAutoCaptions,
    this.onCancelAutoCaptions,
    this.modelDownloadProgress,
  });

  final EditorController controller;
  final bool snap;
  final double zoom;
  final ValueChanged<bool>? onSnapChanged;
  final ValueChanged<double>? onZoomChanged;
  final VoidCallback? onFit;
  final VoidCallback? onAutoCaptions;
  final VoidCallback? onCancelAutoCaptions;
  final double? modelDownloadProgress;

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
            tooltip:
                c.linkAudioOnAdd
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
          const SizedBox(width: 10),
          _AutoCaptionAction(
            controller: c,
            modelDownloadProgress: modelDownloadProgress,
            onGenerate: onAutoCaptions,
            onCancel: onCancelAutoCaptions,
          ),
          const Spacer(),
          if (c.trimFeedback != null) ...[
            Text(
              c.trimFeedback!,
              style: CcType.style(
                size: 11,
                weight: CcType.medium,
                color:
                    c.trimAtLimit ? CcColors.warning : CcColors.textSecondary,
              ),
            ),
            const SizedBox(width: 12),
          ],
          _ToolIcon(
            icon: LucideIcons.zoomOut,
            tooltip: 'Zoom out (⌘−)',
            onTap:
                onZoomChanged == null
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
            onTap:
                onZoomChanged == null
                    ? null
                    : () => onZoomChanged!((zoom + 0.1).clamp(0, 1)),
          ),
          _ToolIcon(
            icon: LucideIcons.scan,
            tooltip: 'Zoom to fit (\\)',
            onTap: onFit,
          ),
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
            color:
                !enabled
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

class _AutoCaptionAction extends StatelessWidget {
  const _AutoCaptionAction({
    required this.controller,
    this.modelDownloadProgress,
    this.onGenerate,
    this.onCancel,
  });

  final EditorController controller;
  final double? modelDownloadProgress;
  final VoidCallback? onGenerate;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final job = controller.autoCaptionJob;
    final downloading = modelDownloadProgress != null;
    final transcribing = controller.autoCaptionBusy;
    final progress = downloading ? modelDownloadProgress : job?.progress;
    final busy = downloading || transcribing;
    final percent = ((progress ?? 0) * 100).clamp(0, 100).round();
    final label =
        downloading
            ? 'Model $percent%'
            : transcribing
            ? 'Captions $percent%'
            : 'Auto captions';

    return CcTooltip(
      message:
          busy
              ? 'Click to cancel'
              : 'Generate local captions from the selected clip, or the longest clip with audio',
      child: CcTappable(
        key: const ValueKey('auto-captions-action'),
        onTap: busy ? onCancel : onGenerate,
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: busy ? CcColors.textClipPlate : CcColors.elevated,
            border: Border.all(
              color: busy ? CcColors.textClip : CcColors.borderStrong,
            ),
            borderRadius: CcRadius.brSm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CcIcon(
                busy ? LucideIcons.x : LucideIcons.captions,
                size: 12,
                color: busy ? CcColors.textClip : CcColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: CcType.style(
                  size: 11,
                  weight: CcType.medium,
                  color: busy ? CcColors.textPrimary : CcColors.textSecondary,
                ),
              ),
            ],
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
    const first = _HintStep(
      number: '1',
      label: 'Import your rushes',
      active: true,
    );
    const second = _HintStep(
      number: '2',
      label: 'Drag them onto the timeline',
      active: false,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        return Center(
          child:
              compact
                  ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      first,
                      SizedBox(height: 8),
                      CcIcon(
                        LucideIcons.arrowDown,
                        size: 14,
                        color: CcColors.textTertiary,
                      ),
                      SizedBox(height: 8),
                      second,
                    ],
                  )
                  : const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      first,
                      SizedBox(width: 10),
                      CcIcon(
                        LucideIcons.arrowRight,
                        size: 14,
                        color: CcColors.textTertiary,
                      ),
                      SizedBox(width: 10),
                      second,
                    ],
                  ),
        );
      },
    );
  }
}

class _HintStep extends StatelessWidget {
  const _HintStep({
    required this.number,
    required this.label,
    required this.active,
  });

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
