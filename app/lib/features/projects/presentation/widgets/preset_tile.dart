import 'package:flutter/widgets.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';

/// Aspect-ratio preset in the "New project" dialog. The swatch is a small
/// plate drawn in the tile's own proportions.
class PresetTile extends StatelessWidget {
  const PresetTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.swatchSize,
    required this.selected,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final Size swatchSize;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: CcDeco.selectableTile(selected: selected).copyWith(
          border: Border.all(
            color: selected ? CcColors.accent : CcColors.borderStrong,
            width: selected ? 2 : 1,
          ),
          color: CcColors.elevated,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 40,
              width: double.infinity,
              child: Center(
                child: Container(
                  width: swatchSize.width,
                  height: swatchSize.height,
                  decoration: BoxDecoration(
                    color: selected ? CcColors.accent : CcColors.textTertiary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(title, style: CcType.style(size: 13, weight: CcType.semibold)),
            const SizedBox(height: 10),
            Text(subtitle, style: CcType.tiny),
          ],
        ),
      ),
    );
  }
}
