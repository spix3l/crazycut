import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../../core/design/tokens.dart';
import '../../../../../core/widgets/primitives.dart';
import 'inspector_row.dart';

/// Stacked, reorderable effects with their parameters inline.
class EffectsTab extends StatelessWidget {
  const EffectsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CcTappable(
            onTap: () {},
            child: Container(
              height: 33,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: CcColors.elevated,
                borderRadius: CcRadius.brMd,
                border: CcBorders.allStrong,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CcIcon(LucideIcons.plus, size: 13),
                  const SizedBox(width: 6),
                  Text(
                    'Add effect',
                    style: CcType.style(
                      size: 12,
                      weight: CcType.medium,
                      color: CcColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          CcSectionHeader(
            'EFFECT STACK',
            trailing: Text('applied top → down', style: CcType.micro),
          ),
          const SizedBox(height: 12),
          const _EffectCard(
            name: 'Exposure',
            rows: [InspectorRow(label: 'Exposure', value: '+0.3', progress: 0.62, labelWidth: 64)],
          ),
          const SizedBox(height: 8),
          const _EffectCard(
            name: 'Vignette',
            rows: [
              InspectorRow(label: 'Amount', value: '40%', progress: 0.6, labelWidth: 64),
              InspectorRow(label: 'Softness', value: '60%', progress: 0.7, labelWidth: 64),
            ],
          ),
          const SizedBox(height: 8),
          const _EffectCard(name: 'Gaussian Blur', rows: [], collapsed: true),
        ],
      ),
    );
  }
}

class _EffectCard extends StatelessWidget {
  const _EffectCard({required this.name, required this.rows, this.collapsed = false});

  final String name;
  final List<Widget> rows;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(color: CcColors.elevated, borderRadius: CcRadius.brSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 31,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  const CcIcon(LucideIcons.gripVertical, size: 12, color: CcColors.textTertiary),
                  const SizedBox(width: 8),
                  const CcCheckbox(checked: true, size: 14),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      style: CcType.style(size: 12, weight: CcType.semibold),
                    ),
                  ),
                  CcIcon(
                    collapsed ? LucideIcons.chevronRight : LucideIcons.chevronDown,
                    size: 13,
                    color: CcColors.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  const CcIcon(LucideIcons.x, size: 12, color: CcColors.textTertiary),
                ],
              ),
            ),
          ),
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Column(children: rows),
            ),
        ],
      ),
    );
  }
}

/// In / out animation pickers for a caption.
class TimingTab extends StatelessWidget {
  const TimingTab({super.key});

  static const _animations = [
    (icon: LucideIcons.blend, label: 'Fade'),
    (icon: LucideIcons.zap, label: 'Pop'),
    (icon: LucideIcons.moveHorizontal, label: 'Slide'),
    (icon: LucideIcons.arrowUp, label: 'Rise'),
    (icon: LucideIcons.keyboard, label: 'Typewriter'),
    (icon: LucideIcons.eye, label: 'Blink'),
  ];

  @override
  Widget build(BuildContext context) {
    Widget section(String title, int selected, String speed, double progress) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CcSectionHeader(title),
          const SizedBox(height: 8),
          InspectorChipGrid(
            children: [
              for (var i = 0; i < _animations.length; i++)
                InspectorChip(
                  icon: _animations[i].icon,
                  label: _animations[i].label,
                  selected: i == selected,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 0),
            child: InspectorRow(
              label: 'Speed',
              value: speed,
              progress: progress,
              labelWidth: 60,
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section('IN ANIMATION', 0, '1.0x', 0.55),
          const SizedBox(height: 18),
          section('OUT ANIMATION', 3, '0.8x', 0.45),
        ],
      ),
    );
  }
}

/// Transition type gallery plus duration, easing and alignment.
class TransitionTab extends StatelessWidget {
  const TransitionTab({super.key});

  static const _types = [
    (icon: LucideIcons.blend, label: 'Cross Dissolve'),
    (icon: LucideIcons.moon, label: 'Dip to Black'),
    (icon: LucideIcons.sun, label: 'Dip to White'),
    (icon: LucideIcons.moveHorizontal, label: 'Slide'),
    (icon: LucideIcons.arrowRightLeft, label: 'Push'),
    (icon: LucideIcons.scanSearch, label: 'Zoom'),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CcSectionHeader(
            'TYPE',
            trailing: const CcIcon(LucideIcons.search, size: 12, color: CcColors.textTertiary),
          ),
          const SizedBox(height: 8),
          InspectorChipGrid(
            children: [
              for (var i = 0; i < _types.length; i++)
                InspectorChip(
                  icon: _types[i].icon,
                  label: _types[i].label,
                  selected: i == 0,
                  height: 53,
                  iconSize: 16,
                ),
            ],
          ),
          const SizedBox(height: 16),
          CcSectionHeader('DURATION'),
          const SizedBox(height: 8),
          const InspectorRow(
            label: 'Length',
            value: '0.5s',
            progress: 0.3,
            labelWidth: 60,
            locked: true,
          ),
          const SizedBox(height: 16),
          CcSectionHeader('EASING'),
          const SizedBox(height: 8),
          const CcDropdown(
            value: 'Ease in-out',
            height: 33,
            fontSize: 12,
            width: double.infinity,
            bordered: true,
          ),
          const SizedBox(height: 16),
          CcSectionHeader('ALIGNMENT'),
          const SizedBox(height: 8),
          CcSegmented(
            expand: true,
            selectedIndex: 1,
            children: [
              for (final label in ['Start', 'Center', 'End'])
                Text(
                  label,
                  style: CcType.style(
                    size: 11,
                    weight: label == 'Center' ? CcType.semibold : CcType.medium,
                    color: label == 'Center' ? CcColors.textPrimary : CcColors.textTertiary,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
