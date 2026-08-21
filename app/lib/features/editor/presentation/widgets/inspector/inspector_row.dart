import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';

/// Label · slider · value · keyframe · reset — the workhorse row of every
/// inspector tab.
class InspectorRow extends StatelessWidget {
  const InspectorRow({
    super.key,
    required this.label,
    required this.value,
    required this.progress,
    this.keyframed = false,
    this.locked = false,
    this.labelWidth = 70,
  });

  final String label;
  final String value;

  /// 0..1 position of the slider handle.
  final double progress;
  final bool keyframed;
  final bool locked;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            SizedBox(
              width: labelWidth,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CcType.style(size: 11, color: CcColors.textSecondary),
              ),
            ),
            Expanded(child: CcSlider(value: progress)),
            const SizedBox(width: 10),
            SizedBox(
              width: 34,
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: CcType.style(size: 11),
              ),
            ),
            const SizedBox(width: 8),
            CcIcon(
              keyframed ? LucideIcons.diamond : LucideIcons.diamond,
              size: 11,
              color: keyframed ? CcColors.accent : CcColors.textTertiary,
            ),
            const SizedBox(width: 8),
            CcIcon(
              locked ? LucideIcons.lock : LucideIcons.rotateCcw,
              size: 11,
              color: CcColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Icon + label chip used by the animation and transition galleries.
class InspectorChip extends StatelessWidget {
  const InspectorChip({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    this.height = 46,
    this.iconSize = 14,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final double height;
  final double iconSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        height: height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        decoration: CcDeco.selectableTile(selected: selected, radius: CcRadius.sm),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CcIcon(
              icon,
              size: iconSize,
              color: selected ? CcColors.accent : CcColors.textSecondary,
            ),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CcType.style(
                size: 9,
                weight: CcType.medium,
                color: selected ? CcColors.textPrimary : CcColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fixed-column grid of [InspectorChip]s.
class InspectorChipGrid extends StatelessWidget {
  const InspectorChipGrid({
    super.key,
    required this.children,
    this.columns = 3,
    this.gap = 6,
  });

  final List<Widget> children;
  final int columns;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final slice = children.sublist(i, (i + columns).clamp(0, children.length));
      rows.add(Row(
        children: [
          for (var c = 0; c < columns; c++) ...[
            if (c > 0) SizedBox(width: gap),
            Expanded(child: c < slice.length ? slice[c] : const SizedBox.shrink()),
          ],
        ],
      ));
    }
    return Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          rows[i],
        ],
      ],
    );
  }
}
