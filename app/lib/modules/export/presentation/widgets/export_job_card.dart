part of 'export_queue_panel.dart';

/// Job row: name, state, progress and the actions for that state (EXP-11).
class ExportJobCard extends StatelessWidget {
  const ExportJobCard({super.key, required this.job, required this.service});

  final ExportJob job;
  final ExportService service;

  @override
  Widget build(BuildContext context) {
    final (icon, iconColor) = switch (job.state) {
      ExportState.running => (LucideIcons.loaderCircle, CcColors.accent),
      ExportState.queued => (LucideIcons.clock3, CcColors.textTertiary),
      ExportState.completed => (LucideIcons.circleCheck, CcColors.success),
      ExportState.failed => (LucideIcons.circleAlert, CcColors.error),
      ExportState.cancelled => (LucideIcons.circleSlash, CcColors.textTertiary),
    };
    final barColor = switch (job.state) {
      ExportState.completed => CcColors.success,
      ExportState.failed => CcColors.error,
      _ => CcColors.accent,
    };

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
                  job.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CcType.style(size: 12, weight: CcType.semibold),
                ),
              ),
              const SizedBox(width: 8),
              // Running jobs show no icon here: the bar below and the line
              // under it already say how far along this job is, and a ring
              // saying it a third time was both redundant and unreadable —
              // at 1% it renders as a stray dot rather than as progress.
              if (job.state != ExportState.running)
                CcIcon(icon, size: 14, color: iconColor)
              else
                const SizedBox(width: 14, height: 14),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: ColoredBox(color: CcColors.elevated2),
                  ),
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: job.progress.clamp(0, 1),
                      child: ColoredBox(color: barColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(job.statusLine, style: CcType.micro),
          const SizedBox(height: 8),
          _Actions(job: job, service: service),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.job, required this.service});

  final ExportJob job;
  final ExportService service;

  @override
  Widget build(BuildContext context) {
    Widget action(String label, IconData icon, VoidCallback onTap) =>
        CcTappable(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CcIcon(icon, size: 12, color: CcColors.textSecondary),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: CcType.style(size: 11, color: CcColors.textSecondary),
                ),
              ],
            ),
          ),
        );

    return switch (job.state) {
      ExportState.queued || ExportState.running => Row(
        children: [
          action('Cancel', LucideIcons.x, () => service.cancel(job.id)),
        ],
      ),
      ExportState.completed => Row(
        children: [
          action(
            'Reveal',
            LucideIcons.folderOpen,
            () => _reveal(job.outputPath),
          ),
          const SizedBox(width: 6),
          action('Open', LucideIcons.play, () => _open(job.outputPath)),
          const SizedBox(width: 6),
          action(
            'Copy path',
            LucideIcons.copy,
            () => Clipboard.setData(ClipboardData(text: job.outputPath)),
          ),
        ],
      ),
      ExportState.failed => Row(
        children: [
          action(
            'Copy diagnostics',
            LucideIcons.clipboardList,
            () => Clipboard.setData(
              ClipboardData(text: service.diagnosticsFor(job)),
            ),
          ),
        ],
      ),
      ExportState.cancelled => const SizedBox.shrink(),
    };
  }

  static void _reveal(String path) {
    if (Platform.isMacOS) {
      Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      Process.run('explorer', ['/select,', path]);
    } else {
      Process.run('xdg-open', [File(path).parent.path]);
    }
  }

  static void _open(String path) {
    if (Platform.isMacOS) {
      Process.run('open', [path]);
    } else if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', path]);
    } else {
      Process.run('xdg-open', [path]);
    }
  }
}
