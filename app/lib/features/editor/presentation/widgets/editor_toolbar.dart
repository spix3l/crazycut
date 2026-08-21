import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';

/// Top chrome of the editor: navigation + history, the tool picker centred on
/// the window, and the playback-quality / export cluster.
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
    this.saveState = '',
  });

  static const _tools = [LucideIcons.mousePointer2, LucideIcons.scissors, LucideIcons.type];

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

  /// "Saved" / "Saving…" hint next to the export button.
  final String saveState;

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
                CcTappable(
                  onTap: canUndo ? onUndo : null,
                  child: CcIcon(
                    LucideIcons.undo2,
                    size: 16,
                    color: canUndo ? CcColors.textPrimary : CcColors.textTertiary,
                  ),
                ),
                const SizedBox(width: 14),
                CcTappable(
                  onTap: canRedo ? onRedo : null,
                  child: CcIcon(
                    LucideIcons.redo2,
                    size: 16,
                    color: canRedo ? CcColors.textPrimary : CcColors.textTertiary,
                  ),
                ),
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
                  CcIconButton(
                    icon: _tools[i],
                    active: i == selectedTool,
                    onPressed: onToolChanged == null ? null : () => onToolChanged!(i),
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
                if (saveState.isNotEmpty) ...[
                  Text(saveState, style: CcType.tiny),
                  const SizedBox(width: 10),
                ],
                CcIconButton(
                  icon: LucideIcons.magnet,
                  active: snap,
                  outlined: true,
                  onPressed: onSnapChanged == null ? null : () => onSnapChanged!(!snap),
                ),
                const SizedBox(width: 10),
                const CcDropdown(value: 'Auto', height: 29, fontSize: 12),
                const SizedBox(width: 11),
                const CcDivider(),
                const SizedBox(width: 11),
                CcButton(
                  label: 'Export',
                  icon: LucideIcons.upload,
                  height: 32,
                  radius: CcRadius.sm,
                  onPressed: onExport,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
