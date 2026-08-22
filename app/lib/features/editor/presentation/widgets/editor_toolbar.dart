import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../data/autosave.dart';
import '../../../../state/export_service.dart';

/// Top chrome of the editor: navigation + history, the tool picker centred on
/// the window, and the save-state / export cluster.
class EditorToolbar extends StatelessWidget {
  const EditorToolbar({
    super.key,
    this.selectedTool = 0,
    this.onToolChanged,
    this.onBack,
    this.onExport,
    this.onUndo,
    this.onRedo,
    this.canUndo = false,
    this.canRedo = false,
    this.snap = true,
    this.onSnapChanged,
    this.saveState = SaveState.saved,
    this.projectName = '',
    this.onRename,
    this.offlineCount = 0,
    this.onRelink,
    this.mixerOpen = false,
    this.onToggleMixer,
    this.onCollectMedia,
    this.onDiagnostics,
  });

  static const _tools = [
    (LucideIcons.mousePointer2, 'Select (V)'),
    (LucideIcons.scissors, 'Blade (B)'),
    (LucideIcons.type, 'Text (T) — M2'),
  ];

  final int selectedTool;
  final ValueChanged<int>? onToolChanged;
  final VoidCallback? onBack;
  final VoidCallback? onExport;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final bool canUndo;
  final bool canRedo;
  final bool snap;
  final ValueChanged<bool>? onSnapChanged;
  final SaveState saveState;
  final String projectName;
  final VoidCallback? onRename;

  /// Missing-media count; non-zero surfaces the relink affordance (IMP-15).
  final int offlineCount;
  final VoidCallback? onRelink;
  final bool mixerOpen;
  final VoidCallback? onToggleMixer;
  final VoidCallback? onCollectMedia;
  final VoidCallback? onDiagnostics;

  String get _saveLabel => switch (saveState) {
        SaveState.saved => 'Saved',
        SaveState.saving => 'Saving…',
        SaveState.dirty => 'Unsaved changes',
        SaveState.failed => 'Save failed',
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(color: CcColors.panel, border: CcBorders.bottom),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CcTappable(
                  onTap: onBack,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CcIcon(LucideIcons.chevronLeft, size: 16),
                      const SizedBox(width: 6),
                      Text('Projects', style: CcType.small),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                const CcDivider(),
                const SizedBox(width: 14),
                CcTooltip(
                  message: 'Undo (⌘Z)',
                  child: CcTappable(
                    onTap: canUndo ? onUndo : null,
                    child: CcIcon(
                      LucideIcons.undo2,
                      size: 16,
                      color: canUndo ? CcColors.textPrimary : CcColors.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                CcTooltip(
                  message: 'Redo (⇧⌘Z)',
                  child: CcTappable(
                    onTap: canRedo ? onRedo : null,
                    child: CcIcon(
                      LucideIcons.redo2,
                      size: 16,
                      color: canRedo ? CcColors.textPrimary : CcColors.textTertiary,
                    ),
                  ),
                ),
                if (projectName.isNotEmpty) ...[
                  const SizedBox(width: 14),
                  const CcDivider(),
                  const SizedBox(width: 14),
                  Builder(
                    builder: (context) => CcTappable(
                      // The project name doubles as the project menu: rename,
                      // collect media (PRJ-14) and diagnostics live here
                      // because there is no menu bar in this shell.
                      onTap: () => showCcMenuBelow(context, [
                        CcMenuItem('Rename project…',
                            icon: LucideIcons.pencil, onTap: onRename),
                        CcMenuItem('Collect media to project folder…',
                            icon: LucideIcons.folderInput,
                            separatorBefore: true,
                            onTap: onCollectMedia),
                        CcMenuItem('Save diagnostics…',
                            icon: LucideIcons.lifeBuoy, onTap: onDiagnostics),
                      ]),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            projectName,
                            style: CcType.style(size: 12, weight: CcType.medium),
                          ),
                          const SizedBox(width: 4),
                          const CcIcon(LucideIcons.chevronDown,
                              size: 12, color: CcColors.textTertiary),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            height: 37,
            padding: const EdgeInsets.all(3),
            decoration: const BoxDecoration(
              color: CcColors.elevated,
              borderRadius: CcRadius.brMd,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _tools.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  CcTooltip(
                    message: _tools[i].$2,
                    child: CcIconButton(
                      icon: _tools[i].$1,
                      active: i == selectedTool,
                      onPressed: onToolChanged == null ? null : () => onToolChanged!(i),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (offlineCount > 0) ...[
                  CcTappable(
                    onTap: onRelink,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CcIcon(LucideIcons.unlink, size: 13, color: CcColors.warning),
                        const SizedBox(width: 6),
                        Text(
                          'Relink $offlineCount',
                          style: CcType.style(size: 11, color: CcColors.warning),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Text(
                  _saveLabel,
                  style: CcType.style(
                    size: 11,
                    color: saveState == SaveState.failed
                        ? CcColors.error
                        : CcColors.textTertiary,
                  ),
                ),
                const SizedBox(width: 10),
                CcTooltip(
                  message: 'Mixer',
                  child: CcIconButton(
                    icon: LucideIcons.sliders,
                    active: mixerOpen,
                    outlined: true,
                    onPressed: onToggleMixer,
                  ),
                ),
                const SizedBox(width: 11),
                CcTooltip(
                  message: 'Snapping (hold ⌃ to bypass)',
                  child: CcIconButton(
                    icon: LucideIcons.magnet,
                    active: snap,
                    outlined: true,
                    onPressed: onSnapChanged == null ? null : () => onSnapChanged!(!snap),
                  ),
                ),
                const SizedBox(width: 11),
                const CcDivider(),
                const SizedBox(width: 11),
                _ExportButton(onPressed: onExport),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// Export button with the queue's progress ring (EXP-9): while jobs run it
/// shows how far along they are without opening the panel.
class _ExportButton extends StatefulWidget {
  const _ExportButton({this.onPressed});

  final VoidCallback? onPressed;

  @override
  State<_ExportButton> createState() => _ExportButtonState();
}

class _ExportButtonState extends State<_ExportButton> {
  final ExportService _service = ExportService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final active = _service.activeCount;
    if (active == 0) {
      return CcButton(
        label: 'Export',
        icon: LucideIcons.upload,
        height: 32,
        radius: CcRadius.sm,
        onPressed: widget.onPressed,
      );
    }
    final running = _service.jobs
        .where((j) => j.state == ExportState.running)
        .toList();
    final progress = running.isEmpty
        ? 0.0
        : running.map((j) => j.progress).reduce((a, b) => a + b) / running.length;
    return CcTooltip(
      message: '$active export${active == 1 ? '' : 's'} in the queue',
      child: CcTappable(
        onTap: widget.onPressed,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: CcColors.accent,
            borderRadius: BorderRadius.circular(CcRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CustomPaint(
                  painter: _RingPainter(progress: progress),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(progress * 100).round()}%',
                style: CcType.style(
                  size: 13,
                  weight: CcType.semibold,
                  color: CcColors.onAccent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = CcColors.onAccent.withValues(alpha: 0.3);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = CcColors.onAccent;
    canvas.drawArc(rect.deflate(1), 0, math.pi * 2, false, track);
    canvas.drawArc(rect.deflate(1), -math.pi / 2,
        math.pi * 2 * progress.clamp(0, 1), false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
