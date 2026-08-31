import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:crazycut_app/core/design/tokens.dart';
import 'package:crazycut_app/core/widgets/empty_state.dart';
import 'package:crazycut_app/core/widgets/primitives.dart';
import 'package:crazycut_app/modules/export/application/export_service.dart';

part 'export_job_card.dart';

/// Right-hand slide-over listing queued, running and finished exports
/// (EXP-9/11). It is a live view of [ExportService]: the queue keeps running
/// whether or not this panel is on screen.
class ExportQueuePanel extends StatelessWidget {
  const ExportQueuePanel({super.key, required this.service, this.onClose});

  static const double width = 300;

  final ExportService service;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final jobs = service.jobs.reversed.toList();
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
                if (jobs.any(
                  (j) =>
                      j.state == ExportState.completed ||
                      j.state == ExportState.failed ||
                      j.state == ExportState.cancelled,
                ))
                  CcTooltip(
                    message: 'Clear finished',
                    child: CcTappable(
                      onTap: service.clearFinished,
                      child: const CcIcon(LucideIcons.eraser, size: 14),
                    ),
                  ),
                const SizedBox(width: 12),
                CcTappable(
                  onTap: onClose,
                  child: const CcIcon(LucideIcons.x, size: 16),
                ),
              ],
            ),
          ),
          Expanded(
            child:
                jobs.isEmpty
                    ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: CcEmptyState(
                        icon: LucideIcons.inbox,
                        title: 'No exports yet',
                        description:
                            'Queued and running jobs will appear here.',
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
                      itemBuilder:
                          (context, i) =>
                              ExportJobCard(job: jobs[i], service: service),
                    ),
          ),
        ],
      ),
    );
  }
}
