import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../models/project_summary.dart';

/// 320×245 card: gradient thumbnail with badges, then name + meta row.
class ProjectCard extends StatelessWidget {
  const ProjectCard({super.key, required this.project, this.onOpen, this.onMenu});

  final ProjectSummary project;
  final VoidCallback? onOpen;

  /// Anchors the ⋯ menu to the ⋯ button itself.
  final ValueChanged<BuildContext>? onMenu;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onOpen,
      builder: (context, hovered, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: CcColors.panel,
          borderRadius: CcRadius.brLg,
          border: Border.all(color: hovered ? CcColors.borderStrong : CcColors.border),
        ),
        child: child,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 320 / 180,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(CcRadius.lg)),
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: project.thumbnail),
                child: Stack(
                  children: [
                    Positioned(
                      left: 12,
                      top: 12,
                      child: CcBadge(project.resolutionLabel),
                    ),
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: CcBadge(project.duration),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CcType.cardTitle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Builder(
                      builder: (buttonContext) => GestureDetector(
                        onTapDown: onMenu == null ? null : (_) => onMenu!(buttonContext),
                        child: const CcIcon(LucideIcons.ellipsis, size: 16),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(project.lastOpened, style: CcType.small),
                    const SizedBox(width: 6),
                    Text('·', style: CcType.style(size: 12, color: CcColors.textTertiary)),
                    const SizedBox(width: 6),
                    Text(project.aspect, style: CcType.style(size: 12, color: CcColors.textTertiary)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
