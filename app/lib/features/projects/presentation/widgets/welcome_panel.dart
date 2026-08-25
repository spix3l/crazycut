import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';

/// First-launch hero: badge, headline, and three ways to get started.
class WelcomePanel extends StatelessWidget {
  const WelcomePanel({super.key, this.onOpenSample, this.onNewProject, this.onImportFiles});

  final VoidCallback? onOpenSample;
  final VoidCallback? onNewProject;
  final VoidCallback? onImportFiles;

  @override
  Widget build(BuildContext context) {
    final cards = [
      _WelcomeCard(
        icon: LucideIcons.circlePlay,
        title: 'Open sample project',
        description: 'See CrazyCut in action with a guided 45s edit.',
        cta: 'Download & open (~40 MB)',
        onTap: onOpenSample,
      ),
      _WelcomeCard(
        icon: LucideIcons.squarePlus,
        title: 'New project',
        description: 'Start from a blank timeline with your own presets.',
        cta: 'Choose a preset',
        onTap: onNewProject,
      ),
      _WelcomeCard(
        icon: LucideIcons.upload,
        title: 'Import files',
        description: 'Drop in your rushes and start cutting right away.',
        cta: 'Select files or folders',
        onTap: onImportFiles,
      ),
    ];

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: CcColors.accentDim,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: CcColors.accent),
          ),
          child: const CcIcon(LucideIcons.clapperboard, size: 26, color: CcColors.accent),
        ),
        const SizedBox(height: 10),
        Text("Let's make something", style: CcType.style(size: 24, weight: CcType.bold)),
        const SizedBox(height: 10),
        Text(
          'Start editing in seconds. No account, no watermark.',
          style: CcType.style(size: 14, color: CcColors.textSecondary),
        ),
        const SizedBox(height: 32),
        IntrinsicHeight(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                SizedBox(width: 263, child: cards[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.cta,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final String cta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return CcTappable(
      onTap: onTap,
      builder: (context, hovered, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: CcColors.panel,
          borderRadius: CcRadius.brLg,
          border: Border.all(color: hovered ? CcColors.accent : CcColors.border),
        ),
        child: child,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: CcColors.elevated,
              borderRadius: BorderRadius.circular(10),
            ),
            child: CcIcon(icon, size: 18, color: CcColors.textPrimary),
          ),
          const SizedBox(height: 10),
          Text(title, style: CcType.style(size: 14, weight: CcType.semibold)),
          const SizedBox(height: 10),
          Text(
            description,
            style: CcType.style(size: 12, color: CcColors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                cta,
                style: CcType.style(size: 12, weight: CcType.semibold, color: CcColors.accent),
              ),
              const SizedBox(width: 5),
              const CcIcon(LucideIcons.arrowRight, size: 12, color: CcColors.accent),
            ],
          ),
        ],
      ),
    );
  }
}
