import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/cc_dialog.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../data/autosave.dart';

enum RecoveryChoice { restoreAutosave, openSaved, openBackup }

/// Launch-time notice that a previous session ended without a clean save
/// (PRJ-8). Clicking through opens the chooser.
class RecoveryBanner extends StatelessWidget {
  const RecoveryBanner({
    super.key,
    required this.candidates,
    required this.onReview,
    required this.onOpenBackup,
  });

  final List<RecoveryCandidate> candidates;
  final ValueChanged<RecoveryCandidate> onReview;
  final void Function(RecoveryCandidate candidate, String backupPath) onOpenBackup;

  @override
  Widget build(BuildContext context) {
    final first = candidates.first;
    final extra = candidates.length - 1;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
      decoration: const BoxDecoration(
        color: CcColors.elevated,
        border: CcBorders.bottom,
      ),
      child: Row(
        children: [
          const CcIcon(LucideIcons.lifeBuoy, size: 15, color: CcColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              extra > 0
                  ? '“${first.name}” and $extra other project'
                      '${extra == 1 ? '' : 's'} have unsaved changes from a previous session.'
                  : '“${first.name}” has unsaved changes from a previous session.',
              style: CcType.style(size: 12, color: CcColors.textSecondary),
            ),
          ),
          CcButton(
            label: 'Review',
            height: 30,
            radius: CcRadius.sm,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            onPressed: () => onReview(first),
          ),
        ],
      ),
    );
  }
}

/// Restore / discard / browse-backups chooser.
Future<RecoveryChoice?> showRecoveryChooser(
  BuildContext context, {
  required RecoveryCandidate candidate,
  required List<File> backups,
}) {
  final completer = Completer<RecoveryChoice?>();
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  void finish(RecoveryChoice? choice) {
    if (completer.isCompleted) return;
    entry.remove();
    completer.complete(choice);
  }

  String stamp(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';

  entry = OverlayEntry(
    builder: (context) => CcModalBarrier(
      onDismiss: () => finish(null),
      child: CcDialogShell(
        title: 'Recover “${candidate.name}”',
        width: 560,
        onClose: () => finish(null),
        sections: [
          Text(
            'CrazyCut found autosaved changes newer than the saved project — '
            'about ${candidate.unsavedWindow.inSeconds}s of work.',
            style: CcType.style(size: 12, color: CcColors.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 14),
          _Choice(
            icon: LucideIcons.rotateCcw,
            title: 'Restore autosave',
            subtitle: 'Saved ${stamp(candidate.autosaveModified)} · recommended',
            onTap: () => finish(RecoveryChoice.restoreAutosave),
          ),
          _Choice(
            icon: LucideIcons.fileText,
            title: 'Open last saved',
            subtitle: 'Saved ${stamp(candidate.projectModified)} · discards the autosave',
            onTap: () => finish(RecoveryChoice.openSaved),
          ),
          if (backups.isNotEmpty) ...[
            const SizedBox(height: 10),
            CcSectionHeader('BACKUPS (${backups.length})'),
            const SizedBox(height: 6),
            SizedBox(
              height: 120,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final backup in backups.take(20))
                      _Choice(
                        icon: LucideIcons.history,
                        title: backup.path.split(Platform.pathSeparator).last,
                        subtitle: 'Saved ${stamp(backup.statSync().modified)}',
                        dense: true,
                        onTap: () => finish(RecoveryChoice.openBackup),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
        actions: [
          CcButton(
            label: 'Decide later',
            kind: CcButtonKind.secondary,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            onPressed: () => finish(null),
          ),
        ],
      ),
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.dense = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: CcTappable(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 8 : 12),
          decoration: BoxDecoration(
            color: CcColors.elevated,
            borderRadius: CcRadius.brMd,
            border: CcBorders.allStrong,
          ),
          child: Row(
            children: [
              CcIcon(icon, size: 14, color: CcColors.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CcType.style(size: 12, weight: CcType.semibold),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: CcType.nano),
                  ],
                ),
              ),
              const CcIcon(LucideIcons.chevronRight, size: 14, color: CcColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the OS file manager with the file selected (PRJ-2).
Future<void> revealInFileManager(String path) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    } else {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
  } on Object {
    // Revealing is a convenience; failures stay silent.
  }
}
