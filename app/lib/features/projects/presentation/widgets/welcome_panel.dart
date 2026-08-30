import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';

/// First-launch screen: a primary lane into the app (new project), with the
/// sample and import paths as real alternatives below it. Left-anchored: the
/// app is a tool, and this screen is its front door, not a landing page.
class WelcomePanel extends StatelessWidget {
  const WelcomePanel({
    super.key,
    this.onOpenSample,
    this.onNewProject,
    this.onImportFiles,
  });

  final VoidCallback? onOpenSample;
  final VoidCallback? onNewProject;
  final VoidCallback? onImportFiles;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(48, 40, 48, 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Start cutting',
              style: CcType.style(size: 26, weight: CcType.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'CrazyCut edits locally. No account, no watermark.',
              style: CcType.style(size: 14, color: CcColors.textSecondary),
            ),
            const SizedBox(height: 28),
            _PrimaryLane(
              title: 'New project',
              description: 'Pick a resolution preset and start from a blank '
                  'timeline.',
              icon: LucideIcons.squarePlus,
              onTap: onNewProject,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 148,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _SecondaryCard(
                      icon: LucideIcons.circlePlay,
                      title: 'Open sample project',
                      description: 'See CrazyCut in action with a guided '
                          'offline edit.',
                      onTap: onOpenSample,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SecondaryCard(
                      icon: LucideIcons.upload,
                      title: 'Import files',
                      description: 'Drop in your rushes and start cutting '
                          'right away.',
                      onTap: onImportFiles,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The primary path: filled, larger, one clear action. The colour signals
/// "this is where you start", not decoration.
class _PrimaryLane extends StatelessWidget {
  const _PrimaryLane({
    required this.title,
    required this.description,
    required this.icon,
    this.onTap,
  });

  final String title;
  final String description;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      builder:
          (context, hovered, child) => AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: hovered
                  ? Color.lerp(CcColors.accentDim, CcColors.accent, 0.18)
                  : CcColors.accentDim,
              borderRadius: CcRadius.brLg,
              border: Border.all(color: CcColors.accent),
            ),
            child: child,
          ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: CcColors.accent,
              borderRadius: BorderRadius.circular(11),
            ),
            child: CcIcon(icon, size: 20, color: CcColors.onAccent),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: CcType.style(size: 15, weight: CcType.semibold),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: CcType.style(
                    size: 12,
                    color: CcColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const CcIcon(LucideIcons.arrowRight, size: 16, color: CcColors.accent),
        ],
      ),
    );
  }
}

/// Secondary path: quiet surface, smaller affordance. Present, but not
/// competing with the primary lane.
class _SecondaryCard extends StatelessWidget {
  const _SecondaryCard({
    required this.icon,
    required this.title,
    required this.description,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      builder:
          (context, hovered, child) => AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: CcColors.panel,
              borderRadius: CcRadius.brLg,
              border: Border.all(
                color: hovered ? CcColors.borderStrong : CcColors.border,
              ),
            ),
            child: child,
          ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: CcColors.elevated,
              borderRadius: BorderRadius.circular(9),
            ),
            child: CcIcon(icon, size: 16, color: CcColors.textPrimary),
          ),
          const SizedBox(height: 12),
          Text(title, style: CcType.style(size: 13, weight: CcType.semibold)),
          const SizedBox(height: 6),
          Text(
            description,
            style: CcType.style(
              size: 12,
              color: CcColors.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
