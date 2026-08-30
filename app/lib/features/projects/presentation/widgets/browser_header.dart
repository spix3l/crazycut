import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';

/// 72px app header: brand mark on the left, search + sort when available, then
/// the persistent open/new project actions on the right.
class BrowserHeader extends StatefulWidget {
  const BrowserHeader({
    super.key,
    this.showSearch = true,
    this.onOpenProject,
    this.onNewProject,
    this.onSearchChanged,
    this.sortLabel = 'Last opened',
    this.onSortTapped,
  });

  final bool showSearch;
  final VoidCallback? onOpenProject;
  final VoidCallback? onNewProject;
  final ValueChanged<String>? onSearchChanged;
  final String sortLabel;

  /// Anchors the sort menu to the sort control itself.
  final ValueChanged<BuildContext>? onSortTapped;

  @override
  State<BrowserHeader> createState() => _BrowserHeaderState();
}

class _BrowserHeaderState extends State<BrowserHeader> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => widget.onSearchChanged?.call(_search.text));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

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
              color: CcColors.elevated,
              borderRadius: BorderRadius.circular(8),
              border: CcBorders.allStrong,
            ),
            child: const CcIcon(LucideIcons.scissors, size: 16, color: CcColors.textSecondary),
          ),
          const SizedBox(width: 10),
          Text('CrazyCut', style: CcType.appName),
          const Spacer(),
          if (widget.showSearch) ...[
            SizedBox(
              width: 260,
              child: CcTextField(
                placeholder: 'Search projects',
                icon: LucideIcons.search,
                height: 32,
                bordered: false,
                controller: _search,
              ),
            ),
            const SizedBox(width: 12),
            Builder(
              builder: (sortContext) => GestureDetector(
                onTapDown: widget.onSortTapped == null
                    ? null
                    : (_) => widget.onSortTapped!(sortContext),
                child: CcDropdown(value: widget.sortLabel, width: 120, radius: CcRadius.md),
              ),
            ),
            const SizedBox(width: 12),
          ],
          CcButton(
            label: 'Open Project',
            icon: LucideIcons.folderOpen,
            kind: CcButtonKind.secondary,
            onPressed: widget.onOpenProject,
          ),
          const SizedBox(width: 10),
          CcButton(
            label: 'New Project',
            icon: LucideIcons.plus,
            onPressed: widget.onNewProject,
          ),
        ],
      ),
    );
  }
}
