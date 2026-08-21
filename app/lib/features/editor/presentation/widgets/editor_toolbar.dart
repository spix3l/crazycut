import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../data/autosave.dart';

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
                  CcTappable(
                    onTap: onRename,
                    child: Text(
                      projectName,
                      style: CcType.style(size: 12, weight: CcType.medium),
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
