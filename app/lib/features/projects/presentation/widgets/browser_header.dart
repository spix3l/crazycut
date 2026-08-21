import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';

/// 72px app header: brand mark on the left, search + sort + primary action
/// on the right. On first launch only the primary action is shown.
class BrowserHeader extends StatelessWidget {
  const BrowserHeader({super.key, this.showSearch = true, this.onNewProject});

  final bool showSearch;
  final VoidCallback? onNewProject;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      decoration: const BoxDecoration(color: CcColors.panel, border: CcBorders.bottom),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: CcColors.accent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const CcIcon(LucideIcons.scissors, size: 16, color: CcColors.onAccent),
          ),
          const SizedBox(width: 10),
          Text('CrazyCut', style: CcType.appName),
          const Spacer(),
          if (showSearch) ...[
            const SizedBox(
              width: 260,
              child: CcTextField(
                placeholder: 'Search projects',
                icon: LucideIcons.search,
                height: 32,
                bordered: false,
              ),
            ),
            const SizedBox(width: 12),
            const CcDropdown(value: 'Last opened', width: 120, radius: CcRadius.md),
            const SizedBox(width: 12),
          ],
          CcButton(
            label: 'New Project',
            icon: LucideIcons.plus,
            onPressed: onNewProject,
          ),
        ],
      ),
    );
  }
}
