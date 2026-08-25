import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../app/session.dart';
import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/cc_dialog.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../state/shorts_flow.dart';
import '../widgets/short_candidate_card.dart';

/// Find shorts (SHT-1 … SHT-11).
///
/// A non-opaque route like Export, so the editor stays mounted underneath and
/// previewing a candidate is visible behind the dialog.
@RoutePage(name: 'ShortsReviewRoute')
class ShortsReviewScreen extends StatefulWidget {
  const ShortsReviewScreen({super.key});

  @override
  State<ShortsReviewScreen> createState() => _ShortsReviewScreenState();
}

class _ShortsReviewScreenState extends State<ShortsReviewScreen> {
  ShortsFlow? _flow;
  String? _toast;

  @override
  void initState() {
    super.initState();
    final session = AppSession.instance;
    if (session.hasProject && session.path != null) {
      final flow = ShortsFlow(
        controller: session.editor,
        projectPath: session.path!,
      )..addListener(_bump);
      _flow = flow;
      WidgetsBinding.instance.addPostFrameCallback((_) => flow.start());
    }
  }

  @override
  void dispose() {
    _flow?.removeListener(_bump);
    _flow?.dispose();
    super.dispose();
  }

  void _bump() {
    if (mounted) setState(() {});
  }

  void _close() {
    _flow?.cancel();
    context.router.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final flow = _flow;
    return CcModalBarrier(
      onDismiss: _close,
      child: CcDialogShell(
        title: 'Find shorts',
        width: 660,
        onClose: _close,
        sections: [
          if (flow == null)
            const _Message(
              icon: LucideIcons.circleAlert,
              text: 'Open a project first.',
            )
          else
            ..._body(flow),
        ],
        actions: [
          if (flow != null && flow.isBusy)
            CcButton(
              label: 'Cancel',
              kind: CcButtonKind.secondary,
              onPressed: _close,
            )
          else
            CcButton(label: 'Done', onPressed: _close),
        ],
      ),
    );
  }

  List<Widget> _body(ShortsFlow flow) {
    return [
      switch (flow.stage) {
        ShortsStage.idle => const _Message(
          icon: LucideIcons.sparkles,
          text: 'Getting ready…',
        ),
        ShortsStage.transcribing => _Progress(
          label: 'Listening to the recording',
          detail:
              flow.transcriptionJob?.statusLine ??
              'Transcribing on this machine — nothing is uploaded.',
          progress: flow.transcriptionJob?.progress,
        ),
        ShortsStage.proposing => const _Progress(
          label: 'Looking for moments that stand alone',
          detail: 'Sending the transcript text to your configured provider.',
          progress: null,
        ),
        ShortsStage.reviewing || ShortsStage.done => _results(flow),
      },
      if (_toast != null) ...[
        const SizedBox(height: 4),
        Row(
          children: [
            const CcIcon(
              LucideIcons.circleCheck,
              size: 15,
              color: CcColors.success,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _toast!,
                style: CcType.style(size: 12, color: CcColors.textSecondary),
              ),
            ),
          ],
        ),
      ],
    ];
  }

  Widget _results(ShortsFlow flow) {
    final error = flow.error;
    if (flow.candidates.isEmpty) {
      return _Message(
        icon: LucideIcons.searchX,
        text: error ?? 'Nothing to show.',
      );
    }

    final media = flow.asset;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '${flow.pending.length} of ${flow.candidates.length} left to '
              'review',
              style: CcType.label,
            ),
            const Spacer(),
            if (flow.accepted.isNotEmpty)
              CcBadge('${flow.accepted.length} created'),
          ],
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < flow.candidates.length; i++) ...[
          ShortCandidateCard(
            candidate: flow.candidates[i],
            asset: media,
            state: flow.accepted.containsKey(i)
                ? ShortCardState.accepted
                : flow.rejected.contains(i)
                ? ShortCardState.rejected
                : ShortCardState.pending,
            onPreview: () => flow.preview(i),
            onNudgeStart: (delta) => flow.nudge(i, startDelta: delta),
            onNudgeEnd: (delta) => flow.nudge(i, endDelta: delta),
            onReject: () => flow.reject(i),
            onAccept: () async {
              final file = await flow.accept(i);
              if (file != null && mounted) {
                setState(
                  () => _toast =
                      'Created ${file.uri.pathSegments.last}',
                );
              }
            },
          ),
          const SizedBox(height: 10),
        ],
        if (error != null) ...[
          const SizedBox(height: 4),
          Text(error, style: CcType.style(size: 12, color: CcColors.error)),
        ],
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({
    required this.label,
    required this.detail,
    required this.progress,
  });

  final String label;
  final String detail;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: CcType.style(size: 13, weight: CcType.semibold)),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Container(
            height: 6,
            color: CcColors.elevated,
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              // An indeterminate stage still shows a sliver, so the bar never
              // reads as "stuck at zero".
              widthFactor: progress ?? 0.08,
              child: Container(color: CcColors.accent),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          detail,
          style: CcType.style(
            size: 12,
            color: CcColors.textTertiary,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CcIcon(icon, size: 16, color: CcColors.textTertiary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: CcType.style(
              size: 13,
              color: CcColors.textSecondary,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}
