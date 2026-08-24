import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../state/export_service.dart';

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
                if (jobs.any((j) =>
                    j.state == ExportState.completed ||
                    j.state == ExportState.failed ||
                    j.state == ExportState.cancelled))
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
                    itemBuilder: (context, i) =>
                        ExportJobCard(job: jobs[i], service: service),
                  ),
          ),
        ],
      ),
    );
  }
}

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
              job.state == ExportState.running
                  ? _ProgressRing(value: job.progress, color: iconColor)
                  : CcIcon(icon, size: 14, color: iconColor),
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
                      child: ColoredBox(color: CcColors.elevated2)),
                  FractionallySizedBox(
                    widthFactor: job.progress.clamp(0, 1),
                    child: ColoredBox(color: barColor),
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
    Widget action(String label, IconData icon, VoidCallback onTap) => CcTappable(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CcIcon(icon, size: 12, color: CcColors.textSecondary),
                const SizedBox(width: 4),
                Text(label,
                    style: CcType.style(size: 11, color: CcColors.textSecondary)),
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
            action('Reveal', LucideIcons.folderOpen, () => _reveal(job.outputPath)),
            const SizedBox(width: 6),
            action('Open', LucideIcons.play, () => _open(job.outputPath)),
            const SizedBox(width: 6),
            action('Copy path', LucideIcons.copy,
                () => Clipboard.setData(ClipboardData(text: job.outputPath))),
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

/// Small ring that fills to [value] (0–1), replacing the static loader glyph
/// so the header icon actually reads as the job's real encode progress.
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({required this.value, required this.color});

  static const double _size = 14;
  static const double _strokeWidth = 2;

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: CustomPaint(
        painter: _ProgressRingPainter(
          value: value.clamp(0, 1),
          color: color,
          trackColor: CcColors.elevated2,
          strokeWidth: _strokeWidth,
        ),
      ),
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  _ProgressRingPainter({
    required this.value,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double value;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - strokeWidth) / 2;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );
    if (value <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      value * 2 * math.pi,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ProgressRingPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.color != color;
}
