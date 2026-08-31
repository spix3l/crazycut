import 'package:flutter/widgets.dart';

import 'package:crazycut_app/core/design/tokens.dart';

/// Placeholder grid shown while the project browser scans the projects
/// directory (UIX-9). The skeleton matches the real card proportions so the
/// transition to loaded content causes no layout shift.
class ProjectSkeletonGrid extends StatelessWidget {
  const ProjectSkeletonGrid({super.key, this.count = 8});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A quiet "Your projects" stand-in at the same height as the real
          // section title, so the grid lands in the same place.
          Container(height: 24, width: 130, decoration: _plate()),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 20.0;
              const idealWidth = 320.0;
              final columns = ((constraints.maxWidth + gap) /
                      (idealWidth + gap))
                  .floor()
                  .clamp(1, 6);
              final cardWidth =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < count; i++)
                    SizedBox(width: cardWidth, child: const _SkeletonCard()),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  BoxDecoration _plate() => BoxDecoration(
    color: CcColors.elevated,
    borderRadius: BorderRadius.circular(6),
  );
}

/// One project-card-shaped skeleton: poster block + two text lines.
class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 320 / 180,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: CcColors.panel,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(CcRadius.lg),
              ),
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Container(
                  width: 64,
                  height: 14,
                  decoration: BoxDecoration(
                    color: CcColors.elevated,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 120,
                height: 13,
                decoration: BoxDecoration(
                  color: CcColors.elevated,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: 72,
                height: 11,
                decoration: BoxDecoration(
                  color: CcColors.elevated2,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
