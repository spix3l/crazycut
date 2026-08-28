import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/design/tokens.dart';
import '../../../../core/widgets/primitives.dart';
import '../../../../state/onboarding.dart';

class OnboardingChecklist extends StatelessWidget {
  const OnboardingChecklist({super.key, required this.state});

  final OnboardingState state;
  static const _items = <(String, String)>[
    ('preview', 'Press Space to preview the edit'),
    ('timeline', 'Select and trim a timeline clip'),
    ('title', 'Change a title in the inspector'),
    ('export', 'Open Export and render a video'),
  ];

  @override
  Widget build(BuildContext context) {
    if (!state.loaded || state.dismissed) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('onboarding-checklist'),
      width: 310,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CcColors.panel,
        borderRadius: CcRadius.brLg,
        border: CcBorders.allStrong,
        boxShadow: CcDeco.dialogShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const CcIcon(
                LucideIcons.sparkles,
                size: 16,
                color: CcColors.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.finished ? 'You’re ready to create' : 'Your first edit',
                  style: CcType.style(size: 14, weight: CcType.semibold),
                ),
              ),
              CcIconButton(
                icon: LucideIcons.x,
                size: 26,
                iconSize: 14,
                onPressed: () => unawaited(state.dismiss()),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            state.finished
                ? 'Nice work. Dismiss this card and make the sample your own.'
                : 'Try each step in the guided sample and check it off when it feels familiar.',
            style: CcType.style(
              size: 11,
              height: 1.4,
              color: CcColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          for (final item in _items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: CcTappable(
                onTap: () => unawaited(state.toggle(item.$1)),
                child: Row(
                  children: [
                    CcCheckbox(
                      checked: state.isComplete(item.$1),
                      onTap: () => unawaited(state.toggle(item.$1)),
                    ),
                    const SizedBox(width: 9),
                    Expanded(child: Text(item.$2, style: CcType.body)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
