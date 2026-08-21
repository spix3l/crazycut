import 'package:flutter/widgets.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';

/// Codec/target preset in the export dialog.
class ExportPresetTile extends StatelessWidget {
  const ExportPresetTile({
    super.key,
    required this.icon,
    required this.name,
    required this.subtitle,
    required this.selected,
    this.onTap,
  });

  final IconData icon;
  final String name;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      child: Container(
        height: 83,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CcColors.elevated,
          borderRadius: CcRadius.brMd,
          border: Border.all(
            color: selected ? CcColors.accent : CcColors.borderStrong,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            CcIcon(
              icon,
              size: 16,
              color: selected ? CcColors.accent : CcColors.textSecondary,
            ),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CcType.style(size: 12, weight: CcType.semibold),
            ),
            Text(subtitle, style: CcType.micro),
          ],
        ),
      ),
    );
  }
}
