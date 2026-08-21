import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/widgets/primitives.dart';
import '../models/export_job.dart';

/// Right-hand slide-over listing queued, running and finished exports.
class ExportQueuePanel extends StatelessWidget {
  const ExportQueuePanel({super.key, required this.jobs, this.onClose});

  static const double width = 300;

  final List<ExportJob> jobs;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: CcColors.panel,
        border: Border(left: BorderSide(color: CcColors.borderStrong)),
        boxShadow: CcDeco.slideOverShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: const BoxDecoration(border: CcBorders.bottom),
            child: Row(
              children: [
                Text('Export queue', style: CcType.panelTitle),
                const Spacer(),
                CcTappable(
                  onTap: onClose,
                  child: const CcIcon(LucideIcons.x, size: 16),
                ),
              ],
            ),
          ),
          Expanded(
            child: jobs.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: CcEmptyState(
                      icon: LucideIcons.inbox,
                      title: 'No exports yet',
                      description: 'Queued and running jobs will appear here.',
                      badgeSize: 44,
                      badgeRadius: 12,
                      iconSize: 20,
                      bordered: false,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: jobs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, i) => ExportJobCard(job: jobs[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Job row: name, state icon, progress bar and a status line.
class ExportJobCard extends StatelessWidget {
  const ExportJobCard({super.key, required this.job});

  final ExportJob job;

  @override
  Widget build(BuildContext context) {
    final (icon, iconColor) = switch (job.state) {
      ExportJobState.encoding => (LucideIcons.loaderCircle, CcColors.accent),
      ExportJobState.queued => (LucideIcons.clock3, CcColors.textTertiary),
      ExportJobState.completed => (LucideIcons.circleCheck, CcColors.success),
    };
    final barColor =
        job.state == ExportJobState.completed ? CcColors.success : CcColors.accent;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CcColors.elevated,
        borderRadius: CcRadius.brMd,
        border: CcBorders.allStrong,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  job.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.style(size: 12, weight: CcType.semibold),
                ),
              ),
              const SizedBox(width: 8),
              CcIcon(icon, size: 14, color: iconColor),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(color: CcColors.elevated2)),
                  FractionallySizedBox(
                    widthFactor: job.progress.clamp(0, 1),
                    child: ColoredBox(color: barColor),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(job.status, style: CcType.micro),
        ],
      ),
    );
  }
}
